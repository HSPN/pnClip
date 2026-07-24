#!/bin/sh
set -eu

app_path=$1
signing_dir=$2
certificate_name=$3
signed_app="$signing_dir/PNClip.app"

identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    /usr/bin/awk -v name="$certificate_name" '$0 ~ "\\\"" name "\\\"" { print $2; exit }')

if [ -n "$identity" ]; then
    echo "$certificate_name 인증서($identity)로 서명합니다."
else
    certificate_status=0
    /usr/bin/security find-certificate -a -c "$certificate_name" >/dev/null 2>&1 || certificate_status=$?
    if [ "$certificate_status" -eq 0 ]; then
        echo "$certificate_name 인증서는 있지만 사용할 수 있는 개인 키를 찾지 못했습니다." >&2
        echo "잘못된 ad-hoc 서명으로 권한이 초기화되는 것을 막기 위해 빌드를 중단합니다." >&2
        exit 1
    fi
    if [ "$certificate_status" -ne 44 ]; then
        echo "키체인 조회에 실패했습니다(오류 $certificate_status). ad-hoc 서명으로 대체하지 않습니다." >&2
        exit 1
    fi
    identity=-
    echo "$certificate_name 인증서가 이 Mac에 없어 ad-hoc 서명을 사용합니다."
fi

/bin/rm -rf "$signing_dir"
/bin/mkdir -p "$signing_dir"
/usr/bin/ditto "$app_path" "$signed_app"
/usr/bin/xattr -cr "$signed_app"
/usr/bin/codesign --force --deep --timestamp=none --sign "$identity" \
    --identifier com.example.PNClip "$signed_app"
/bin/rm -rf "$app_path"
/usr/bin/ditto "$signed_app" "$app_path"
/usr/bin/xattr -cr "$app_path"
/bin/rm -rf "$signing_dir"

actual_identity=$(/usr/bin/codesign -dvv "$app_path" 2>&1 |
    /usr/bin/awk -F= '/^Authority=/{ print $2; exit }')
if [ "$identity" != "-" ] && [ "$actual_identity" != "$certificate_name" ]; then
    echo "서명 검증 실패: 예상 인증서 '$certificate_name', 실제 '$actual_identity'" >&2
    exit 1
fi
