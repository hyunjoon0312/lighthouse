#!/usr/bin/env python3
"""Convert the pinned KAIR FFDNet color model to a fixed Core ML conv network."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import tempfile
import urllib.request
from pathlib import Path
from typing import Any, Mapping

import coremltools as ct
import numpy as np
import torch
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from torch import nn


UPSTREAM_REVISION = "fc1732f4a4514e42ce15e5b3a1e18c828af47a1e"
WEIGHTS_URL = "https://github.com/cszn/KAIR/releases/download/v1.0/ffdnet_color_clip.pth"
WEIGHTS_SHA256 = "99a5081e32afdaa25df3ded11aa16447556692e550906caed320db31324af5ce"
EXPECTED_VERSIONS = {
    "coremltools": "9.0",
    "numpy": "2.4.6",
    "torch": "2.7.0",
}
INPUT_SHAPE = (13, 160, 160)
OUTPUT_SHAPE = (12, 160, 160)
CONV_CHANNELS = (13,) + (96,) * 11 + (12,)
PARITY_MAX_ABSOLUTE_ERROR = 2e-4
PARITY_MAX_MEAN_ABSOLUTE_ERROR = 2e-5
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "Sources"
    / "LighthouseCore"
    / "Resources"
    / "FFDNet.mlmodel"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert pinned KAIR ffdnet_color_clip weights to Core ML."
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="Local checkpoint. The pinned official release is downloaded when omitted.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Core ML output path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--fixtures",
        type=int,
        default=3,
        help="Number of deterministic PyTorch/Core ML parity fixtures (minimum 2).",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="Optional path for the JSON conversion and verification report.",
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_versions() -> None:
    actual = {
        "coremltools": ct.__version__,
        "numpy": np.__version__,
        "torch": torch.__version__.split("+")[0],
    }
    if actual != EXPECTED_VERSIONS:
        raise RuntimeError(
            "Conversion environment differs from the pinned toolchain: "
            f"expected {EXPECTED_VERSIONS}, got {actual}"
        )


def download_source(destination: Path) -> None:
    request = urllib.request.Request(
        WEIGHTS_URL,
        headers={"User-Agent": "Lighthouse-FFDNet-converter/1"},
    )
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def require_source_hash(path: Path) -> None:
    actual = sha256(path)
    if actual != WEIGHTS_SHA256:
        raise RuntimeError(
            f"Unexpected checkpoint SHA-256 for {path}: "
            f"expected {WEIGHTS_SHA256}, got {actual}"
        )


def expected_state_shapes() -> dict[str, tuple[int, ...]]:
    shapes: dict[str, tuple[int, ...]] = {}
    for layer_index, (input_channels, output_channels) in enumerate(
        zip(CONV_CHANNELS, CONV_CHANNELS[1:])
    ):
        module_index = layer_index * 2
        shapes[f"model.{module_index}.weight"] = (
            output_channels,
            input_channels,
            3,
            3,
        )
        shapes[f"model.{module_index}.bias"] = (output_channels,)
    return shapes


def load_checkpoint(path: Path) -> dict[str, torch.Tensor]:
    loaded = torch.load(path, map_location="cpu", weights_only=True)
    if not isinstance(loaded, Mapping):
        raise ValueError(f"Expected a state dictionary, got {type(loaded).__name__}")
    expected = expected_state_shapes()
    if set(loaded) != set(expected):
        missing = sorted(set(expected) - set(loaded))
        unexpected = sorted(set(loaded) - set(expected))
        raise ValueError(f"Checkpoint keys differ: missing={missing}, unexpected={unexpected}")

    state: dict[str, torch.Tensor] = {}
    for name, shape in expected.items():
        tensor = loaded[name]
        if not isinstance(tensor, torch.Tensor):
            raise ValueError(f"{name}: expected Tensor, got {type(tensor).__name__}")
        if tensor.dtype != torch.float32 or tuple(tensor.shape) != shape:
            raise ValueError(
                f"{name}: expected Float32 {shape}, got {tensor.dtype} {tuple(tensor.shape)}"
            )
        if not bool(torch.isfinite(tensor).all()):
            raise ValueError(f"{name}: contains non-finite values")
        state[name] = tensor.detach().cpu().contiguous()
    return state


class FFDNetPlanes(nn.Module):
    """The official color FFDNet conv body, after pixel-unshuffle and sigma concat."""

    def __init__(self) -> None:
        super().__init__()
        layers: list[nn.Module] = []
        for layer_index, (input_channels, output_channels) in enumerate(
            zip(CONV_CHANNELS, CONV_CHANNELS[1:])
        ):
            layers.append(
                nn.Conv2d(
                    input_channels,
                    output_channels,
                    kernel_size=3,
                    stride=1,
                    padding=1,
                    bias=True,
                )
            )
            if layer_index != len(CONV_CHANNELS) - 2:
                layers.append(nn.ReLU(inplace=False))
        self.model = nn.Sequential(*layers)

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        return self.model(value)


def make_torch_model(state: Mapping[str, torch.Tensor]) -> FFDNetPlanes:
    model = FFDNetPlanes()
    model.load_state_dict(state, strict=True)
    model.eval()
    return model


def make_coreml_model(state: Mapping[str, torch.Tensor]) -> ct.models.MLModel:
    builder = NeuralNetworkBuilder(
        input_features=[("input", datatypes.Array(*INPUT_SHAPE))],
        output_features=[("output", datatypes.Array(*OUTPUT_SHAPE))],
    )

    input_name = "input"
    for layer_index, (input_channels, output_channels) in enumerate(
        zip(CONV_CHANNELS, CONV_CHANNELS[1:])
    ):
        module_index = layer_index * 2
        is_last = layer_index == len(CONV_CHANNELS) - 2
        convolution_output = "output" if is_last else f"conv_{layer_index:02d}"
        weights = state[f"model.{module_index}.weight"].numpy()
        bias = state[f"model.{module_index}.bias"].numpy()
        builder.add_convolution(
            name=f"conv_{layer_index:02d}",
            kernel_channels=input_channels,
            output_channels=output_channels,
            height=3,
            width=3,
            stride_height=1,
            stride_width=1,
            border_mode="valid",
            groups=1,
            W=np.ascontiguousarray(weights.transpose(2, 3, 1, 0)),
            b=np.ascontiguousarray(bias),
            has_bias=True,
            input_name=input_name,
            output_name=convolution_output,
            dilation_factors=[1, 1],
            padding_top=1,
            padding_bottom=1,
            padding_left=1,
            padding_right=1,
        )
        if not is_last:
            activation_output = f"relu_{layer_index:02d}"
            builder.add_activation(
                name=activation_output,
                non_linearity="RELU",
                input_name=convolution_output,
                output_name=activation_output,
            )
            input_name = activation_output

    spec = builder.spec
    float32_type = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    spec.description.input[0].type.multiArrayType.dataType = float32_type
    spec.description.output[0].type.multiArrayType.dataType = float32_type
    spec.description.input[0].shortDescription = (
        "Float32 sRGB planes: 4*c + 2*dy + dx for a 320x320 RGB tile, then sigma"
    )
    spec.description.output[0].shortDescription = (
        "Float32 denoised sRGB planes in 4*c + 2*dy + dx order"
    )
    spec.description.metadata.author = "Kai Zhang; Core ML conversion by Lighthouse"
    spec.description.metadata.license = "MIT"
    spec.description.metadata.shortDescription = (
        "KAIR FFDNet color_clip 12-convolution denoiser body. "
        "Pixel shuffle/unshuffle are performed by the caller."
    )
    spec.description.metadata.versionString = UPSTREAM_REVISION
    validate_spec(spec)
    return ct.models.MLModel(spec, compute_units=ct.ComputeUnit.CPU_ONLY)


def validate_spec(spec: Any) -> None:
    input_shape = tuple(spec.description.input[0].type.multiArrayType.shape)
    output_shape = tuple(spec.description.output[0].type.multiArrayType.shape)
    if input_shape != INPUT_SHAPE or output_shape != OUTPUT_SHAPE:
        raise RuntimeError(f"Unexpected Core ML shapes: {input_shape} -> {output_shape}")
    layers = list(spec.neuralNetwork.layers)
    convolutions = [layer for layer in layers if layer.WhichOneof("layer") == "convolution"]
    activations = [layer for layer in layers if layer.WhichOneof("layer") == "activation"]
    if len(convolutions) != 12 or len(activations) != 11 or len(layers) != 23:
        raise RuntimeError(
            "Expected 12 convolutions and 11 ReLUs, got "
            f"{len(convolutions)} convolutions, {len(activations)} activations"
        )
    for index, layer in enumerate(convolutions):
        convolution = layer.convolution
        expected_values = 3 * 3 * CONV_CHANNELS[index] * CONV_CHANNELS[index + 1]
        if len(convolution.weights.floatValue) != expected_values:
            raise RuntimeError(f"conv_{index:02d}: weights are not stored as Float32")
        if convolution.weights.float16Value or convolution.weights.rawValue:
            raise RuntimeError(f"conv_{index:02d}: found non-Float32 weight storage")


def predict_torch(model: nn.Module, sample: np.ndarray) -> np.ndarray:
    with torch.inference_mode():
        tensor = torch.from_numpy(np.ascontiguousarray(sample[np.newaxis, ...]))
        return model(tensor).cpu().numpy()[0]


def predict_coreml(model: ct.models.MLModel, sample: np.ndarray) -> np.ndarray:
    return np.asarray(model.predict({"input": sample})["output"], dtype=np.float32)


def validate_parity(
    torch_model: nn.Module, coreml_model: ct.models.MLModel, fixtures: int
) -> dict[str, Any]:
    if fixtures < 2:
        raise ValueError("At least two parity fixtures are required")
    records = []
    for seed in range(fixtures):
        rng = np.random.default_rng(seed)
        rgb_planes = rng.random((12, 160, 160), dtype=np.float32)
        sigma = np.full((1, 160, 160), (seed + 1) * 25.0 / 255.0, dtype=np.float32)
        sample = np.concatenate((rgb_planes, sigma), axis=0)
        expected = predict_torch(torch_model, sample)
        actual = predict_coreml(coreml_model, sample)
        if expected.shape != OUTPUT_SHAPE or actual.shape != OUTPUT_SHAPE:
            raise RuntimeError(
                f"Fixture {seed}: expected {OUTPUT_SHAPE}, got {expected.shape} and {actual.shape}"
            )
        absolute_error = np.abs(expected - actual)
        record = {
            "seed": seed,
            "sigma": float(sigma[0, 0, 0]),
            "max_absolute_error": float(absolute_error.max()),
            "mean_absolute_error": float(absolute_error.mean()),
        }
        if record["max_absolute_error"] > PARITY_MAX_ABSOLUTE_ERROR:
            raise RuntimeError(f"Fixture {seed}: max parity error failed: {record}")
        if record["mean_absolute_error"] > PARITY_MAX_MEAN_ABSOLUTE_ERROR:
            raise RuntimeError(f"Fixture {seed}: mean parity error failed: {record}")
        records.append(record)
    return {
        "fixtures": records,
        "maximum_absolute_error": max(item["max_absolute_error"] for item in records),
        "maximum_mean_absolute_error": max(
            item["mean_absolute_error"] for item in records
        ),
        "max_absolute_error_limit": PARITY_MAX_ABSOLUTE_ERROR,
        "max_mean_absolute_error_limit": PARITY_MAX_MEAN_ABSOLUTE_ERROR,
    }


def pixel_unshuffle(image: np.ndarray) -> np.ndarray:
    channels, height, width = image.shape
    if channels != 3 or height % 2 or width % 2:
        raise ValueError(f"Expected even CHW RGB image, got {image.shape}")
    return (
        image.reshape(channels, height // 2, 2, width // 2, 2)
        .transpose(0, 2, 4, 1, 3)
        .reshape(12, height // 2, width // 2)
    )


def pixel_shuffle(planes: np.ndarray) -> np.ndarray:
    if planes.shape[0] != 12:
        raise ValueError(f"Expected 12 planes, got {planes.shape}")
    _, height, width = planes.shape
    return (
        planes.reshape(3, 2, 2, height, width)
        .transpose(0, 3, 1, 4, 2)
        .reshape(3, height * 2, width * 2)
    )


def synthetic_clean_image() -> np.ndarray:
    coordinates = np.linspace(0.0, 1.0, 320, dtype=np.float32)
    x = np.broadcast_to(coordinates[np.newaxis, :], (320, 320))
    y = np.broadcast_to(coordinates[:, np.newaxis], (320, 320))
    red = 0.12 + 0.58 * x
    green = 0.18 + 0.52 * y
    blue = 0.22 + 0.18 * np.sin(2.0 * np.pi * x) * np.cos(2.0 * np.pi * y)
    image = np.stack((red, green, blue)).astype(np.float32)
    image[:, 72:248, 96:224] += np.array([0.22, 0.10, 0.16], dtype=np.float32)[:, None, None]
    circle = (x - 0.72) ** 2 + (y - 0.28) ** 2 < 0.09**2
    image[:, circle] = np.array([0.18, 0.78, 0.42], dtype=np.float32)[:, None]
    return np.clip(image, 0.0, 1.0)


def validate_synthetic_quality(coreml_model: ct.models.MLModel) -> dict[str, Any]:
    sigma = 25.0 / 255.0
    clean = synthetic_clean_image()
    rng = np.random.default_rng(0xFFD)
    noisy = np.clip(
        clean + rng.normal(0.0, sigma, size=clean.shape).astype(np.float32),
        0.0,
        1.0,
    )
    model_input = np.concatenate(
        (
            pixel_unshuffle(noisy),
            np.full((1, 160, 160), sigma, dtype=np.float32),
        ),
        axis=0,
    )
    denoised = pixel_shuffle(predict_coreml(coreml_model, model_input))
    noisy_mse = float(np.mean((noisy - clean) ** 2, dtype=np.float64))
    denoised_mse = float(np.mean((denoised - clean) ** 2, dtype=np.float64))
    if not math.isfinite(denoised_mse) or denoised_mse >= noisy_mse:
        raise RuntimeError(
            f"Synthetic quality failed: noisy MSE {noisy_mse}, denoised MSE {denoised_mse}"
        )
    return {
        "seed": 0xFFD,
        "sigma": sigma,
        "noisy_mse": noisy_mse,
        "denoised_mse": denoised_mse,
        "mse_ratio": denoised_mse / noisy_mse,
        "mse_reduction_percent": 100.0 * (1.0 - denoised_mse / noisy_mse),
    }


def run(source: Path, output: Path, fixtures: int) -> dict[str, Any]:
    require_versions()
    require_source_hash(source)
    state = load_checkpoint(source)
    torch_model = make_torch_model(state)
    converted = make_coreml_model(state)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ffdnet-coreml-", dir=output.parent) as directory:
        candidate = Path(directory) / output.name
        converted.save(str(candidate))
        saved_model = ct.models.MLModel(
            str(candidate), compute_units=ct.ComputeUnit.CPU_ONLY
        )
        validate_spec(saved_model.get_spec())
        parity = validate_parity(torch_model, saved_model, fixtures)
        quality = validate_synthetic_quality(saved_model)
        candidate.replace(output)
    return {
        "source": str(source),
        "source_url": WEIGHTS_URL,
        "source_sha256": WEIGHTS_SHA256,
        "upstream_revision": UPSTREAM_REVISION,
        "output": str(output),
        "output_sha256": sha256(output),
        "input_shape": list(INPUT_SHAPE),
        "output_shape": list(OUTPUT_SHAPE),
        "convolution_layers": 12,
        "relu_layers": 11,
        "weights": "Float32",
        "python": platform.python_version(),
        "packages": EXPECTED_VERSIONS,
        "parity": parity,
        "synthetic_quality": quality,
    }


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    contents = json.dumps(report, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix=f".{path.name}.", dir=path.parent, delete=False
    ) as handle:
        handle.write(contents)
        temporary = Path(handle.name)
    temporary.replace(path)


def main() -> None:
    args = parse_args()
    if args.source is not None:
        report = run(args.source.resolve(), args.output.resolve(), args.fixtures)
    else:
        with tempfile.TemporaryDirectory(prefix="lighthouse-ffdnet-") as directory:
            source = Path(directory) / "ffdnet_color_clip.pth"
            download_source(source)
            report = run(source, args.output.resolve(), args.fixtures)
    if args.report is not None:
        write_report(args.report.resolve(), report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
