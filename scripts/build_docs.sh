cd "$(dirname "$0")"

xcodebuild docbuild \
  -scheme LiveKit \
  -destination generic/platform=iOS \
  -sdk iphoneos \
  -derivedDataPath ./build_docs/

rsync -a --delete -vh build_docs/Build/Products/Debug-iphoneos/LiveKit.doccarchive \
  ./
