# Google Drive에 사진 올리기

사진을 고른 뒤 **내보내기**(⇧⌘E)를 열고 **보낼 곳 → Google Drive**를 선택합니다. 원본, 편집본 또는 둘 다 올릴 수 있습니다. 현재 사진·선택한 사진·현재 필터 결과 중 업로드 대상을 고릅니다.

- **원본**: RAW·JPEG 등 원래 파일을 그대로 보냅니다. 원본 안의 촬영 정보와 GPS 정보도 포함됩니다. 같은 원본을 쓰는 가상 사본을 여러 개 골라도 원본은 한 번 보냅니다.
- **편집본**: 내보내기의 형식·색 공간·크기·품질·워터마크·GPS 설정으로 만든 파일을 보냅니다. 가상 사본은 각각의 보정 결과를 보냅니다.
- **원본과 편집본**: 위 두 종류를 함께 보냅니다. 편집본의 이름이 원본과 같아지면 편집본에 `-edited`를 붙입니다.

Google 계정을 연결하고 업로드할 폴더를 고른 뒤 업로드를 누릅니다. 처음에는 폴더 이름에 `Lighthouse` 등을 입력하고 **폴더 만들기**를 누르세요. 폴더 목록에는 Lighthouse가 만든 폴더만 나옵니다. 완료 후 폴더를 Drive에서 열어 결과를 확인할 수 있습니다.

## 처음 연결하기

이 소스 빌드에는 공용 Google OAuth 클라이언트가 들어 있지 않습니다. Google Cloud에서 데스크톱 앱용 설정을 한 번 만들고, 받은 JSON을 앱에서 불러옵니다. Google 로그인에는 시스템 브라우저를 사용합니다. 설정 JSON과 로그인 토큰은 이 Mac의 키체인에 저장하며 카탈로그나 저장소에 기록하지 않습니다.

1. [Google Cloud Console](https://console.cloud.google.com/)에서 프로젝트를 만들거나 사용할 프로젝트를 선택합니다.
2. **API 및 서비스 → 라이브러리**에서 **Google Drive API**를 찾아 사용 설정합니다.
3. **Google Auth Platform**에서 앱 이름·지원 이메일 등 동의 화면을 설정합니다. 개인 Google 계정이라면 외부 사용자를 선택하고, 테스트 상태에서는 사용할 Google 계정을 테스트 사용자로 추가합니다. 데이터 액세스 범위는 `https://www.googleapis.com/auth/drive.file`입니다.
4. **클라이언트 → 클라이언트 만들기**에서 애플리케이션 유형을 **데스크톱 앱**으로 고릅니다. 만든 클라이언트의 JSON을 다운로드합니다. 웹 애플리케이션·서비스 계정용 JSON은 사용할 수 없습니다.
5. Lighthouse의 **내보내기 → 보낼 곳 → Google Drive**에서 **OAuth JSON 가져오기…**를 누르고 받은 파일을 선택합니다. 이어서 **Google 계정 연결…**을 누르고, 브라우저에서 사용할 계정과 권한을 확인한 뒤 앱으로 돌아옵니다.

데스크톱 앱은 로그인 결과를 이 Mac의 임시 loopback 주소로 받으므로 웹사이트나 별도 서버가 필요하지 않습니다. 인증 방식은 [Google 데스크톱 OAuth 안내](https://developers.google.com/identity/protocols/oauth2/native-app)를 따릅니다.

Google Cloud 프로젝트가 외부 사용자용 **테스트** 상태이면 이 Drive 권한의 refresh token은 7일 뒤 만료될 수 있습니다. 다시 연결하면 됩니다. 배포하려면 프로젝트의 게시 상태와 Google의 앱 검증 요구사항을 별도로 확인하세요. [Google 토큰 만료 안내](https://developers.google.com/identity/protocols/oauth2#expiration)

## 업로드 동작

업로드 버튼을 누른 시점의 사진과 설정으로 한 파일씩 처리합니다. 보정본은 임시 파일로 만든 뒤 전송하며, 각 파일의 전송이 끝나거나 취소되면 바로 정리합니다. 같은 이름의 편집본은 번호를 붙여 구분합니다. 원본 파일과 카탈로그의 로컬 내보내기 기록은 바꾸지 않습니다.

진행률은 사진 개수 기준이며, 완료·실패 결과에는 전송한 파일 수를 표시합니다. 일부 파일이 실패하면 해당 이름과 이유를 표시합니다. 중지하면 다음 파일을 시작하지 않지만, 이미 Drive에 도착한 파일은 남습니다. 통신이 끊겨 서버의 완료 응답을 받지 못한 경우에는 Drive에서 결과를 먼저 확인한 뒤 다시 업로드하세요. 같은 이름으로 다시 보내면 새 파일이 생길 수 있습니다.

파일을 자동 공개하거나 링크 공유 권한을 바꾸지 않습니다. 업로드한 파일의 접근 권한은 선택한 Drive 폴더의 기존 공유 설정을 따릅니다. 업로드는 사용자가 직접 실행할 때만 하며 카탈로그·편집 이력·LUT 보관함은 동기화하지 않습니다.

**이 Mac에서 연결 해제**는 로컬 로그인 정보를 지웁니다. Google 계정에 부여한 권한까지 취소하려면 [Google 계정의 연결 관리](https://myaccount.google.com/connections)에서 Lighthouse에 사용한 OAuth 앱을 제거하세요.

## 현재 범위와 검증

Google Drive 데스크톱 동기화 앱은 필요하지 않습니다. 접근 권한은 앱에서 만든 파일에 사용하는 `drive.file`로 제한합니다. 기존 임의 폴더 선택·공유 드라이브 탐색·자동 동기화·앱을 재시작한 뒤 전송 이어하기는 포함하지 않습니다. [Google 권한 범위 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

파일 전송에는 Drive의 resumable 업로드 경로를 사용합니다. 새 파일 ID를 먼저 확보해, 전송 응답을 놓쳤을 때 같은 ID로 완료 여부를 확인합니다. [Google 업로드 안내](https://developers.google.com/workspace/drive/api/guides/manage-uploads)

실제 Google 계정 연결·업로드 검증과 네트워크를 모사한 테스트 결과는 구분하여 [검증 기록](verification.md)에 남깁니다.
