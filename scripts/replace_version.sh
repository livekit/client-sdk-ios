#!/bin/sh
# This script is invoked by nanpa with the new version set in VERSION.
# ed is used instead of sed to make this script POSIX compliant (run on Mac or Linux runner).

if [ -z "${VERSION}" ]; then
    echo "Error: VERSION is not set. Exiting..."
    exit 1
fi

replace() {
    ed -s "$1" >/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: unable to replace version in $1" >&2
        exit 1
    fi
}

# 1. Podspec version & tag
# -----------------------------------------
replace ./LiveKitClient.podspec <<EOF
,s/spec.version = "[^"]*"/spec.version = "${VERSION}"/g
,s/:tag => "[^"]*"/:tag => "${VERSION}"/g
w
q
EOF

# 2. README.md, installation guide
# -----------------------------------------
replace ./README.md <<EOF
,s/upToNextMajor("[^"]*")/upToNextMajor("${VERSION}")/g
w
q
EOF

# 3. LiveKitSDK class, static version constant
# -----------------------------------------
replace ./Sources/LiveKit/LiveKit.swift <<EOF
,s/static let version = "[^"]*"/static let version = "${VERSION}"/g
w
q
EOF