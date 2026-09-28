#!/usr/bin/env python3
"""Convert the pinned OpenCV Zoo SFace ONNX model to Core ML and verify parity."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import tempfile
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from onnx import numpy_helper


UPSTREAM_REVISION = "47534e27c9851bb1128ccc0102f1145e27f23f98"
ONNX_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
SOURCE_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
    f"{UPSTREAM_REVISION}/models/face_recognition_sface/"
    "face_recognition_sface_2021dec.onnx"
)
EXPECTED_VERSIONS = {
    "coremltools": "9.0",
    "numpy": "2.4.6",
    "onnx": "1.23.0",
    "onnxruntime": "1.30.0",
}
EXPECTED_OPS = Counter(
    {
        "Sub": 1,
        "Mul": 1,
        "Conv": 27,
        "BatchNormalization": 29,
        "PRelu": 27,
        "Dropout": 1,
        "Flatten": 1,
        "Gemm": 1,
    }
)
MAX_ABSOLUTE_ERROR = 1e-4
MAX_RELATIVE_ERROR = 1e-2
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "Sources"
    / "LighthouseCore"
    / "Resources"
    / "SFace.mlmodel"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert the pinned Apache-2.0 OpenCV Zoo SFace model to Core ML."
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="Local ONNX source. The pinned upstream file is downloaded when omitted.",
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
        help="Number of deterministic parity fixtures; must be at least 3.",
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
        "onnx": onnx.__version__,
        "onnxruntime": ort.__version__,
    }
    if actual != EXPECTED_VERSIONS:
        raise RuntimeError(
            "Conversion environment differs from the recorded toolchain: "
            f"expected {EXPECTED_VERSIONS}, got {actual}"
        )


def download_source(destination: Path) -> None:
    request = urllib.request.Request(
        SOURCE_URL,
        headers={"User-Agent": "Lighthouse-SFace-converter/1"},
    )
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def require_source_hash(path: Path) -> None:
    actual = sha256(path)
    if actual != ONNX_SHA256:
        raise RuntimeError(
            f"Unexpected ONNX SHA-256 for {path}: expected {ONNX_SHA256}, got {actual}"
        )


def attribute(node: onnx.NodeProto, name: str, default: Any = None) -> Any:
    matches = [item for item in node.attribute if item.name == name]
    if not matches:
        return default
    if len(matches) != 1:
        raise ValueError(f"{node.name or node.op_type}: duplicate {name} attribute")
    return onnx.helper.get_attribute_value(matches[0])


def require_attributes(node: onnx.NodeProto, allowed: set[str]) -> None:
    present = {item.name for item in node.attribute}
    unknown = present - allowed
    if unknown:
        raise ValueError(
            f"{node.name or node.op_type}: unsupported attributes {sorted(unknown)}"
        )


def load_and_validate_graph(path: Path) -> tuple[onnx.ModelProto, dict[str, np.ndarray]]:
    model = onnx.load(str(path))
    onnx.checker.check_model(model)

    if model.ir_version != 6:
        raise ValueError(f"Expected ONNX IR version 6, got {model.ir_version}")
    opsets = [(entry.domain, entry.version) for entry in model.opset_import]
    if opsets != [("", 11)]:
        raise ValueError(f"Expected default ONNX opset 11, got {opsets}")
    if Counter(node.op_type for node in model.graph.node) != EXPECTED_OPS:
        raise ValueError(
            "Unexpected ONNX operator inventory: "
            f"{Counter(node.op_type for node in model.graph.node)}"
        )

    non_float_initializers = [
        tensor.name
        for tensor in model.graph.initializer
        if tensor.data_type != onnx.TensorProto.FLOAT
    ]
    if non_float_initializers:
        raise ValueError(f"Expected only Float32 initializers, got {non_float_initializers}")
    initializers = {
        tensor.name: np.asarray(numpy_helper.to_array(tensor), dtype=np.float32)
        for tensor in model.graph.initializer
    }
    real_inputs = [item for item in model.graph.input if item.name not in initializers]
    if len(real_inputs) != 1 or real_inputs[0].name != "data":
        raise ValueError(f"Expected data as the only runtime input, got {[x.name for x in real_inputs]}")
    input_shape = [
        dimension.dim_value
        for dimension in real_inputs[0].type.tensor_type.shape.dim
    ]
    if input_shape != [1, 3, 112, 112]:
        raise ValueError(f"Expected ONNX input shape [1, 3, 112, 112], got {input_shape}")
    if len(model.graph.output) != 1 or model.graph.output[0].name != "fc1":
        raise ValueError("Expected fc1 as the only graph output")
    output_shape = [
        dimension.dim_value
        for dimension in model.graph.output[0].type.tensor_type.shape.dim
    ]
    if output_shape != [1, 128]:
        raise ValueError(f"Expected ONNX output shape [1, 128], got {output_shape}")
    return model, initializers


def initializer(
    initializers: dict[str, np.ndarray], name: str, expected_shape: tuple[int, ...]
) -> np.ndarray:
    if name not in initializers:
        raise ValueError(f"Missing initializer {name}")
    value = initializers[name]
    if value.shape != expected_shape:
        raise ValueError(f"{name}: expected shape {expected_shape}, got {value.shape}")
    if not np.all(np.isfinite(value)):
        raise ValueError(f"{name}: initializer contains non-finite values")
    return np.ascontiguousarray(value, dtype=np.float32)


def convert(model: onnx.ModelProto, initializers: dict[str, np.ndarray]) -> ct.models.MLModel:
    builder = NeuralNetworkBuilder(
        input_features=[("data", datatypes.Array(3, 112, 112))],
        output_features=[("fc1", datatypes.Array(128))],
    )

    produced = {"data"}
    consumed_initializers: set[str] = set()

    for node in model.graph.node:
        name = node.name or node.output[0]
        if len(node.output) != 1:
            raise ValueError(f"{name}: exactly one output is required")
        output_name = node.output[0]
        data_inputs = [item for item in node.input if item not in initializers]
        missing = [item for item in data_inputs if item not in produced]
        if missing:
            raise ValueError(f"{name}: inputs are not available in graph order: {missing}")

        if node.op_type in {"Sub", "Mul"}:
            require_attributes(node, set())
            if len(node.input) != 2 or node.input[0] not in produced:
                raise ValueError(f"{name}: only tensor-first scalar {node.op_type} is supported")
            scalar = initializer(initializers, node.input[1], (1,))
            consumed_initializers.add(node.input[1])
            alpha = 1.0 if node.op_type == "Sub" else float(scalar[0])
            beta = -float(scalar[0]) if node.op_type == "Sub" else 0.0
            builder.add_activation(
                name=name,
                non_linearity="LINEAR",
                input_name=node.input[0],
                output_name=output_name,
                params=[alpha, beta],
            )

        elif node.op_type == "Conv":
            require_attributes(
                node,
                {"dilations", "group", "kernel_shape", "pads", "strides"},
            )
            if len(node.input) not in {2, 3}:
                raise ValueError(f"{name}: expected data, weights, and optional bias")
            weights_name = node.input[1]
            if weights_name not in initializers:
                raise ValueError(f"{name}: dynamic convolution weights are unsupported")
            weights_onnx = initializers[weights_name]
            if weights_onnx.ndim != 4:
                raise ValueError(f"{name}: expected rank-4 convolution weights")
            output_channels, kernel_channels, kernel_height, kernel_width = weights_onnx.shape
            kernel_shape = list(attribute(node, "kernel_shape", []))
            if kernel_shape != [kernel_height, kernel_width]:
                raise ValueError(f"{name}: kernel_shape does not match weights")
            strides = list(attribute(node, "strides", [1, 1]))
            dilations = list(attribute(node, "dilations", [1, 1]))
            pads = list(attribute(node, "pads", [0, 0, 0, 0]))
            group = int(attribute(node, "group", 1))
            if len(strides) != 2 or len(dilations) != 2 or len(pads) != 4 or group < 1:
                raise ValueError(f"{name}: invalid convolution settings")
            if output_channels % group != 0:
                raise ValueError(f"{name}: output channels are not divisible by group")
            weights = np.ascontiguousarray(weights_onnx.transpose(2, 3, 1, 0))
            consumed_initializers.add(weights_name)

            bias = None
            has_bias = len(node.input) == 3 and bool(node.input[2])
            if has_bias:
                bias = initializer(initializers, node.input[2], (output_channels,))
                consumed_initializers.add(node.input[2])
            builder.add_convolution(
                name=name,
                kernel_channels=kernel_channels,
                output_channels=output_channels,
                height=kernel_height,
                width=kernel_width,
                stride_height=int(strides[0]),
                stride_width=int(strides[1]),
                border_mode="valid",
                groups=group,
                W=weights,
                b=bias,
                has_bias=has_bias,
                input_name=node.input[0],
                output_name=output_name,
                dilation_factors=[int(dilations[0]), int(dilations[1])],
                padding_top=int(pads[0]),
                padding_left=int(pads[1]),
                padding_bottom=int(pads[2]),
                padding_right=int(pads[3]),
            )

        elif node.op_type == "BatchNormalization":
            require_attributes(node, {"epsilon", "momentum"})
            if len(node.input) != 5:
                raise ValueError(f"{name}: expected five batch normalization inputs")
            gamma_name, beta_name, mean_name, variance_name = node.input[1:]
            if gamma_name not in initializers:
                raise ValueError(f"{name}: dynamic batch normalization is unsupported")
            channels = int(initializers[gamma_name].size)
            gamma = initializer(initializers, gamma_name, (channels,))
            beta = initializer(initializers, beta_name, (channels,))
            mean = initializer(initializers, mean_name, (channels,))
            variance = initializer(initializers, variance_name, (channels,))
            consumed_initializers.update(node.input[1:])
            epsilon = float(attribute(node, "epsilon", 1e-5))
            if not math.isfinite(epsilon) or epsilon <= 0:
                raise ValueError(f"{name}: invalid epsilon {epsilon}")
            builder.add_batchnorm(
                name=name,
                channels=channels,
                gamma=gamma,
                beta=beta,
                mean=mean,
                variance=variance,
                input_name=node.input[0],
                output_name=output_name,
                compute_mean_var=False,
                instance_normalization=False,
                epsilon=epsilon,
            )

        elif node.op_type == "PRelu":
            require_attributes(node, set())
            if len(node.input) != 2 or node.input[1] not in initializers:
                raise ValueError(f"{name}: expected fixed per-channel PReLU weights")
            alpha = initializers[node.input[1]]
            if alpha.ndim != 3 or alpha.shape[1:] != (1, 1):
                raise ValueError(f"{name}: expected PReLU alpha shape (channels, 1, 1)")
            if not np.all(np.isfinite(alpha)):
                raise ValueError(f"{name}: PReLU alpha contains non-finite values")
            consumed_initializers.add(node.input[1])
            builder.add_activation(
                name=name,
                non_linearity="PRELU",
                input_name=node.input[0],
                output_name=output_name,
                params=np.ascontiguousarray(alpha.reshape(-1), dtype=np.float32),
            )

        elif node.op_type == "Dropout":
            require_attributes(node, {"ratio"})
            if len(node.input) != 1:
                raise ValueError(f"{name}: inference dropout must have one input")
            ratio = float(attribute(node, "ratio", 0.5))
            if not 0.0 <= ratio < 1.0:
                raise ValueError(f"{name}: invalid dropout ratio {ratio}")
            builder.add_activation(
                name=name,
                non_linearity="LINEAR",
                input_name=node.input[0],
                output_name=output_name,
                params=[1.0, 0.0],
            )

        elif node.op_type == "Flatten":
            require_attributes(node, {"axis"})
            if len(node.input) != 1 or int(attribute(node, "axis", 1)) != 1:
                raise ValueError(f"{name}: only channel-first flatten with axis=1 is supported")
            builder.add_flatten(
                name=name,
                mode=0,
                input_name=node.input[0],
                output_name=output_name,
            )

        elif node.op_type == "Gemm":
            require_attributes(node, {"alpha", "beta", "transA", "transB"})
            if len(node.input) != 3:
                raise ValueError(f"{name}: expected data, weights, and bias")
            settings = {
                "alpha": float(attribute(node, "alpha", 1.0)),
                "beta": float(attribute(node, "beta", 1.0)),
                "transA": int(attribute(node, "transA", 0)),
                "transB": int(attribute(node, "transB", 0)),
            }
            if settings != {"alpha": 1.0, "beta": 1.0, "transA": 0, "transB": 1}:
                raise ValueError(f"{name}: unsupported Gemm settings {settings}")
            if node.input[1] not in initializers or initializers[node.input[1]].ndim != 2:
                raise ValueError(f"{name}: expected fixed rank-2 Gemm weights")
            weights = np.ascontiguousarray(initializers[node.input[1]], dtype=np.float32)
            output_channels, input_channels = weights.shape
            bias = initializer(initializers, node.input[2], (output_channels,))
            consumed_initializers.update(node.input[1:])
            builder.add_inner_product(
                name=name,
                W=weights,
                b=bias,
                input_channels=input_channels,
                output_channels=output_channels,
                has_bias=True,
                input_name=node.input[0],
                output_name=output_name,
            )

        else:
            raise ValueError(f"{name}: unsupported operator {node.op_type}")

        produced.add(output_name)

    unused = set(initializers) - consumed_initializers
    if unused:
        raise ValueError(f"Initializers were not consumed: {sorted(unused)}")
    if "fc1" not in produced:
        raise ValueError("Conversion did not produce fc1")

    spec = builder.spec
    float32_type = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    spec.description.input[0].type.multiArrayType.dataType = float32_type
    spec.description.output[0].type.multiArrayType.dataType = float32_type
    spec.description.input[0].shortDescription = "RGB face crop, CHW Float32, raw 0...255"
    spec.description.output[0].shortDescription = "Unnormalized 128-dimensional SFace embedding"
    spec.description.metadata.author = (
        "Yaoyao Zhong; OpenCV Zoo; Shenzhen Institute of Artificial Intelligence "
        "and Robotics for Society; Core ML conversion by Lighthouse"
    )
    spec.description.metadata.license = "Apache License 2.0"
    spec.description.metadata.shortDescription = (
        "OpenCV Zoo SFace identity embedding model converted to Core ML."
    )
    spec.description.metadata.versionString = UPSTREAM_REVISION
    return ct.models.MLModel(spec, compute_units=ct.ComputeUnit.CPU_ONLY)


def validate_parity(
    onnx_path: Path, coreml_model: ct.models.MLModel, fixtures: int
) -> dict[str, Any]:
    if fixtures < 3:
        raise ValueError("At least three parity fixtures are required")
    session_options = ort.SessionOptions()
    session_options.log_severity_level = 3
    session = ort.InferenceSession(
        str(onnx_path),
        sess_options=session_options,
        providers=["CPUExecutionProvider"],
    )
    records = []
    for seed in range(fixtures):
        rng = np.random.default_rng(seed)
        sample = rng.integers(0, 256, size=(3, 112, 112), dtype=np.uint16).astype(
            np.float32
        )
        expected = np.asarray(
            session.run(["fc1"], {"data": sample[np.newaxis, ...]})[0],
            dtype=np.float32,
        ).reshape(-1)
        actual = np.asarray(coreml_model.predict({"data": sample})["fc1"]).reshape(-1)
        if expected.shape != (128,) or actual.shape != (128,):
            raise RuntimeError(
                f"Fixture {seed}: expected two 128-vectors, got {expected.shape} and {actual.shape}"
            )
        if not np.all(np.isfinite(expected)) or not np.all(np.isfinite(actual)):
            raise RuntimeError(f"Fixture {seed}: prediction contains non-finite values")
        expected_64 = expected.astype(np.float64)
        actual_64 = actual.astype(np.float64)
        cosine = float(
            np.dot(expected_64, actual_64)
            / (np.linalg.norm(expected_64) * np.linalg.norm(actual_64))
        )
        absolute_error = np.abs(expected - actual)
        relative_error = absolute_error / np.maximum(np.abs(expected), 1e-6)
        record = {
            "seed": seed,
            "cosine": cosine,
            "max_absolute_error": float(absolute_error.max()),
            "mean_absolute_error": float(absolute_error.mean()),
            "max_relative_error": float(relative_error.max()),
            "mean_relative_error": float(relative_error.mean()),
        }
        if cosine <= 0.99999:
            raise RuntimeError(f"Fixture {seed}: cosine parity failed: {record}")
        if record["max_absolute_error"] > MAX_ABSOLUTE_ERROR:
            raise RuntimeError(f"Fixture {seed}: absolute-error parity failed: {record}")
        if record["max_relative_error"] > MAX_RELATIVE_ERROR:
            raise RuntimeError(f"Fixture {seed}: relative-error parity failed: {record}")
        records.append(record)
    return {
        "fixtures": records,
        "minimum_cosine": min(item["cosine"] for item in records),
        "maximum_absolute_error": max(item["max_absolute_error"] for item in records),
        "maximum_relative_error": max(item["max_relative_error"] for item in records),
    }


def run(source: Path, output: Path, fixtures: int) -> dict[str, Any]:
    require_versions()
    require_source_hash(source)
    model, initializers = load_and_validate_graph(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    converted = convert(model, initializers)
    with tempfile.TemporaryDirectory(prefix="sface-coreml-", dir=output.parent) as directory:
        candidate = Path(directory) / output.name
        converted.save(str(candidate))
        saved_model = ct.models.MLModel(
            str(candidate), compute_units=ct.ComputeUnit.CPU_ONLY
        )
        parity = validate_parity(source, saved_model, fixtures)
        candidate.replace(output)
    return {
        "source": str(source),
        "source_url": SOURCE_URL,
        "upstream_revision": UPSTREAM_REVISION,
        "onnx_sha256": ONNX_SHA256,
        "output": str(output),
        "output_sha256": sha256(output),
        "python": platform.python_version(),
        "packages": EXPECTED_VERSIONS,
        "parity": parity,
    }


def main() -> None:
    args = parse_args()
    if args.source is not None:
        report = run(args.source.resolve(), args.output.resolve(), args.fixtures)
    else:
        with tempfile.TemporaryDirectory(prefix="lighthouse-sface-") as directory:
            source = Path(directory) / "sface.onnx"
            download_source(source)
            report = run(source, args.output.resolve(), args.fixtures)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
