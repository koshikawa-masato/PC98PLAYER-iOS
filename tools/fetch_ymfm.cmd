@echo off
rem ymfm (BSD 3-Clause, Aaron Giles) を third_party\ymfm へ取得します。
setlocal
set "DEST=%~dp0..\third_party\ymfm"
where git >nul 2>nul || ( echo git が見つかりません。https://github.com/aaronsgiles/ymfm を %DEST% に展開してください。 & pause & goto :eof )
if not exist "%DEST%\.git" git clone https://github.com/aaronsgiles/ymfm.git "%DEST%"
git -C "%DEST%" checkout --detach 81aec25ccbb98f4873a255f7551ac4dadac59b4a
git -C "%DEST%" apply --check "%~dp0..\third_party\patches\ymfm-adpcm-stream.patch" >nul 2>nul && git -C "%DEST%" apply "%~dp0..\third_party\patches\ymfm-adpcm-stream.patch"
echo Visual Studio でソリューションを再読み込みしてビルドしてください。
pause
