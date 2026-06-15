# Piccolo を Snapdragon (Windows on ARM) でネイティブ実行するまで ── 実践ガイド

> このドキュメントの目的は「何を変えたか」を残すことではなく、**同じことを自分の手でできるようになる**ことです。
> そのため各トピックは「症状 → どう原因にたどり着いたか（思考過程）→ 対処 → そこから学べる一般原則」の順で書いています。
> 本書の手順に対応する差分は、このディレクトリ内のソースと `CMakePresets.json` に反映済みです。

検証環境（2026年6月15日）: Windows 11 ARM64, Visual Studio Community 2026 18.7.0,
VS同梱 CMake 4.3.1-msvc1, clang-cl 22.1.3, Vulkan SDK 1.4.341.1。

## 最短の再現手順

前提:

- Visual Studio 2026で「C++によるデスクトップ開発」とARM64用LLVM/Clangツールを導入済み
- Windows on ARM版 Vulkan SDKを導入し、`VULKAN_SDK`を設定済み

PowerShellでリポジトリの`Piccolo`ディレクトリを開き、次を実行します。

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$cmake = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

& $cmake --preset vs2026-arm64
& $cmake --build --preset vs2026-arm64-release --parallel 8
& $cmake --build --preset vs2026-arm64-debug --parallel 8
```

成功時は`build_vs\Piccolo.slnx`と`bin\PiccoloEditor.exe`が生成されます。
本環境ではRelease/Debugの両方をビルドし、`PiccoloEditor.exe`、`PiccoloParser.exe`、
`libclang.dll`のPE Machineがすべて`0xAA64`（ARM64）であることを確認しました。

CMake GUIを使う場合も、手動でジェネレータを選び直すよりプリセットを渡す方が確実です。

```powershell
cmake-gui --preset=vs2026-arm64
```

GUIが開いたら`Configure`、`Generate`の順に実行します。過去に同じ`build_vs`をMSVCで
構成している場合は、先にGUIの`File > Delete Cache`を実行してください。

---

## 0. 最初に押さえる「考え方」

このプロジェクト全体で繰り返し効いた原則。先に頭に入れておくと、以降の各ステップが「なぜそうするか」で腑に落ちます。

1. **2段階で攻める** — いきなりネイティブARM64を狙わず、まず「x64バイナリをエミュレーションで動かす」ベースラインを作る。こうすると「コードの問題」と「アーキ固有の問題」を分離できる。Windows on ARM は x64 をエミュレートできるので、これが可能。
2. **同梱バイナリは全部アーキ依存だと疑う** — `.lib` / `.dll` / `.exe` がリポジトリに同梱されていたら、それは特定アーキ向け。移植では真っ先に棚卸しする。
3. **ログは最後まで読み、"最初の"エラーを直す** — 後続のエラーは最初のエラーの巻き添えが多い。1個直して再ビルド、を繰り返す。
4. **エラーメッセージを字義通りに受け取る** — 「`stdext` が未定義」「value "3" は無効」等、書いてある通りの意味であることが多い。憶測する前に該当行・該当ヘッダを実際に開く。
5. **「なぜこのGPU/コンパイラ/構成だけ?」を必ず問う** — 移植で出る不具合の多くは「元の環境ではたまたま動いていた」依存。差分（GPUドライバ、STLバージョン、Debug/Release）に注目すると原因が絞れる。
6. **1変更=1検証、増分ビルドで回す** — 複数同時に変えない。原因と効果を1対1で確認する。

---

## 1. 出発点を知る ── 環境とアーキテクチャの把握

移植の最初の作業は「コードを触ること」ではなく「**現状を測ること**」です。

### 1.1 確認すべきもの

| 項目 | 確認コマンド（PowerShell） | なぜ見るか |
|---|---|---|
| CPUアーキ | `$env:PROCESSOR_ARCHITECTURE` | ARM64 か（→ ネイティブの土俵） |
| CMake | `cmake --version` | 新しすぎ/古すぎがトラブル源（後述） |
| Visual Studio | `vswhere -latest -property displayName/installationVersion` | ジェネレータ名・同梱ツールチェーンを知る |
| MSVCクロスコンパイラ | `VC\Tools\MSVC\<ver>\bin\Hostarm64\{arm64,x64,x86}\cl.exe` の有無 | ARM64ホストから x64/arm64 を出せるか |
| Vulkan SDK | `$env:VULKAN_SDK`、`Lib`/`Lib-x64`/`Bin`/`Bin-x64` の有無 | ARM64版が入っているか |

LunarG の Windows-on-ARM 版 SDK では、**`Lib`/`Bin` が ARM64、`Lib-x64`/`Bin-x64` が x64** という構成になっている、という知識が効きます。

### 1.2 「バイナリのアーキ判定」は必須スキル

同梱の `.lib`/`.dll`/`.exe` が何アーキ向けかを判定できると、移植の地図が一気に描けます。PE ヘッダの **Machine フィールド**（`0x8664`=x64, `0xAA64`=ARM64, `0x14c`=x86）を読むだけです。

```powershell
function Arch($p){
  $b=[System.IO.File]::ReadAllBytes($p)
  $pe=[BitConverter]::ToInt32($b,0x3C)        # 0x3C に PE ヘッダのオフセット
  $m=[BitConverter]::ToUInt16($b,$pe+4)       # PE シグネチャ直後が Machine
  switch($m){0x8664{"x64"}0xAA64{"ARM64"}0x14c{"x86"}default{"0x{0:x}" -f $m}}
}
Arch "C:\VulkanSDK\1.4.341.1\Bin\glslangValidator.exe"   # → ARM64
```

> 注: `.lib`（静的/インポートライブラリ）はアーカイブ形式なので、この単純法では読めないことがある。その場合は「同梱フォルダ名（`Win32`/`x64`/`ARM64`）」やセットになっている `.dll` のアーキで判断する。

### 1.3 この時点で見えた地図（Piccoloの場合）

- 同梱 `engine/3rdparty/VulkanSDK/lib/Win32/vulkan-1.lib` → **x64**
- 同梱 `engine/source/meta_parser/3rd_party/LLVM/.../libclang.lib` → **x64**（LLVM 7）
- Jolt は `/arch:AVX2` や `JPH_USE_SSE*` を使う → **x86前提**

→ 「ネイティブARM64化＝この3つ（Vulkan / libclang / Jolt）をどうにかする戦い」だと最初に分かる。これが**戦略の土台**になりました。

---

## 2. 段階1 ── まず x64 ビルドを通す（エミュレーション基準）

同梱依存が全部 x64 なので、x64 をターゲットにすれば**コード自体が動くか**を最速で確認できます。ここで出る問題は「アーキ」ではなく「ツールチェーン/コードの新旧」起因に切り分けられます。

### 2.1 CMakeバージョン地獄（重要な教訓）

2つの新しさが衝突します:

- **VS 2026 のジェネレータ名 `"Visual Studio 18 2026"` を知っているのは新しいCMake（4.x）だけ**
- **古い同梱スクリプト（`cmake_minimum_required(VERSION 3.2)` 等）を許すのは古いCMake（3.x）**

最初のエラーはこれでした:
```
CMake Error at .../tinyobjloader/CMakeLists.txt:5 (cmake_minimum_required):
  Compatibility with CMake < 3.5 has been removed from CMake.
```
→ **診断**: 「新しいCMakeが古い宣言を拒否」と字義通り。
→ **判断**: 古い同梱スクリプトを大量に書き換えるより、**プロジェクトと同時代のCMake 3.x を使う**方が低リスク。だが 3.x は VS 2026 ジェネレータを知らない。
→ **解法**: **Ninja ジェネレータ** を使えばジェネレータ名にVSバージョンを要求しない。`pip install --user cmake==3.31.6` でCMakeを用意し、**VS開発者環境（vcvars）の中で** Ninja を叩く。

```powershell
# x64（ARM64ホスト → x64ターゲットのクロス）。エミュレーションで動く。
cmd /c '"...\VC\Auxiliary\Build\vcvarsall.bat" arm64_x64 && <cmake3.31> -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && <cmake3.31> --build build -j'
```

**学べること**: 「ツールが新しすぎる/古すぎる」は実プロジェクトで頻出。ジェネレータ依存を外す（Ninja化）、または時代の合うツールを用意する、という2手を持っておく。

### 2.2 Jolt の PCH が Ninja で壊れる

```
fatal error C1083: Cannot open precompiled header file: 'Jolt/Jolt.pch'
```
→ **診断**: Jolt の `Jolt.cmake` は手動PCH（`/Yc` でpch.cpp生成、`/Yu` で全ソース使用）。だが「全`/Yu`ソースは`pch.cpp`に依存する」という**依存関係をCMakeに宣言していない**。MSBuildはPCHを暗黙に直列化するので動くが、**Ninjaは並列実行**するので `/Yu` 側が先に走って `.pch` 未生成で落ちる。
→ **対処**: Ninja時は手動PCHを無効化（`NOT CMAKE_GENERATOR MATCHES "Ninja"` でガード）。PCHはビルド速度の最適化に過ぎず、外しても結果は同じ。

**学べること**: 「MSBuildでは動くがNinjaでは壊れる」典型。ジェネレータごとのビルド実行モデル（直列 vs 並列、依存グラフの明示性）の違いを疑う。

### 2.3 新しいMSVCで Jolt が出す他のエラー

- `/WX`（警告をエラー化）で、新MSVCが `UVec4.h` に出す**新しい警告**が致命傷に → `/WX` を外す。
- `JobSystemThreadPool.cpp` の `100us`（chronoリテラル）が未解決 → `#include <chrono>` と `using namespace std::chrono_literals;` を追加。

**学べること**: コンパイラ/STLが新しくなると、(a)新警告が増える、(b)以前は暗黙に通っていた省略（using/include漏れ）が露呈する。古いコードを新ツールチェーンに載せる時の定番。

この段階で `bin\PiccoloEditor.exe`（x64）が完成 → エミュレーションで起動確認。**「コードは動く」ことが確定**し、以降はアーキ問題に集中できる。

---

## 3. 段階2 ── ネイティブARM64化

### 3.1 ターゲットアーキの判定をどう仕込むか

CMake内で「今ARM64をビルドしているか」を確実に知る必要がある。`CMAKE_SYSTEM_PROCESSOR` はクロス時に当てにならない（ホストの値が残る）。**信頼できるのは `CMAKE_CXX_COMPILER_ARCHITECTURE_ID`**（MSVC/clang-cl が設定するターゲットアーキ）。

確信が持てない時は**プローブを書いて確かめる**（これも汎用テク）:
```cmake
# 小さな CMakeLists を作って message で変数を吐かせる
message(STATUS "ARCHID=[${CMAKE_CXX_COMPILER_ARCHITECTURE_ID}] PROC=[${CMAKE_SYSTEM_PROCESSOR}] ID=[${CMAKE_CXX_COMPILER_ID}]")
```
→ ARM64の vcvars + Ninja では `ARCHID=ARM64`。clang-cl でも `ARCHID=ARM64`（一方 `PROC` は `AMD64` と誤報する）。
**この実測があったから、以降のガードを `CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "ARM64"` で統一できた。**

### 3.2 ① Vulkan ── 導入済みARM64 SDKへ向ける（一番やさしい）

同梱は x64 だが、**インストール済みSDKにARM64版がある**（1.2.2の地図）。ヘッダはアーキ非依存なので同梱のまま、**アーキ依存物（`vulkan-1.lib` / `glslangValidator` / 検証レイヤパス）だけ**を `$ENV{VULKAN_SDK}` 配下のARM64版に差し替える。`engine/CMakeLists.txt` にARM64分岐を追加。

検証方法も大事: 生成された `build_arm64/build.ninja` を grep し、リンクとシェーダコンパイルが `C:\VulkanSDK\...\Lib\vulkan-1.lib` / `...\Bin\glslangValidator.exe` を指し、**同梱の `Win32` 参照が消えている**ことを確認した。

**学べること**: 「ヘッダはアーキ非依存／バイナリはアーキ依存」を分けて考える。設定変更は**生成物を grep して効いているか必ず確認**する。

### 3.3 ② libclang ── ビルドツール用のARM64ライブラリを探す

`PiccoloParser`（C++リフレクションのコード生成ツール）が x64 `libclang.lib` にリンク。ネイティブARM64ビルドでは PiccoloParser 自身もARM64になるので、x64 libclangとはリンクできない。

→ **発見**: ダウンロードしに行く前に、**手元にARM64版が無いか探す**。`VC\Tools\Llvm\ARM64\{bin\libclang.dll, lib\libclang.lib}` が **VS 2026に同梱**されていた（LLVM 22）。
→ **判断の根拠**: clang-c の C API は非常に安定（後方互換）なので、同梱の古いヘッダ（LLVM 7）と新しい libclang.dll（LLVM 22）の組み合わせで問題ない。
→ `meta_parser/CMakeLists.txt` にARM64分岐を追加（`$ENV{VCINSTALLDIR}` から導出、`-DPICCOLO_ARM64_LIBCLANG_DIR` で上書き可）。巨大なツールチェーンbin全体ではなく `libclang.dll` 単体コピーに変更。

**学べること**: 不足物は「ダウンロード」の前に「既にマシンにある供給源（VS/SDK同梱）」を当たる。APIの安定性（C API vs C++ ABI）を知っていると、バージョン差を許容できるか判断できる。

### 3.4 ③④ Jolt の SIMD ── そして clang-cl という決め手

最初は素直に「ARM64では x86 フラグ（`/arch:AVX2`, `JPH_USE_SSE*`）を外して NEON 経路に」と考え、`Jolt/Build/CMakeLists.txt` をARM64ガード。すると次のエラー:
```
error C3861: '__builtin_shufflevector': identifier not found
error C3861: '__builtin_clz' / '__builtin_bitreverse32'
```
→ **診断**: `Math.h` を実際に開くと、`#elif defined(JPH_CPU_ARM64)` の枝が**コンパイラ非依存でClang/GCCビルトインを直書き**していた。つまり**この版のJoltはMSVC+ARM64を想定していない**。`__builtin_shufflevector` は Mat44/Vec3/Vec4 に数十箇所あり、MSVC intrinsic への手動置換は非現実的。

→ **判断（重要な分岐点）**: 手で潰すのではなく、**コンパイラを clang-cl に切り替える**。clang-cl は
  - MSVC ABI互換（MSVCでビルドした他オブジェクトやVS提供libと普通にリンクできる）
  - Clangビルトイン（`__builtin_*`）をネイティブに持つ
  ので、Jolt の NEON コードがそのまま通る。**1つの上流バグを、ツールチェーン選択で丸ごと回避**できた。

→ clang-cl では `CMAKE_CXX_COMPILER_ID=Clang` になるので、Jolt の **Clang枝**にある `-mavx2` 等もARM64でガード。あとは `-DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl` で再構成。

結果: `PiccoloEditor.exe` / `PiccoloParser.exe` / `libclang.dll` がすべて **ARM64** に。

**学べること（最重要級）**:
- 上流ライブラリの非対応に当たったら、**ソースを手で直す**以外に **コンパイラを替える**という選択肢がある。clang-cl は「MSVC互換でClang機能が欲しい」時の強力なカード。
- 「修正コストが見合わない」と判断したら早めに方針転換する。`__builtin_shufflevector` 数十個の手動NEON化に突っ込まずに済んだのは、コスト見積もりのおかげ。

---

## 4. Visual Studio プロジェクト（.slnx）を生成する

CLIのNinjaビルドとは別に、IDEで開ける `.sln`(現行は `.slnx`) が欲しい、という要求。VS 2026 同梱の CMake 4.3.1 + VS生成器 + `-A ARM64 -T ClangCL` を使う。

### 4.1 `CMAKE_POLICY_VERSION_MINIMUM` が "3" に汚染される謎を追う

```
CMake Error at FetchContent.cmake:1144 (cmake_policy):
  Invalid CMAKE_POLICY_VERSION_MINIMUM value "3".
```
`-D...=3.5` を渡しても **"3"** と言われる。
→ **追い方**: エラーが指す `FetchContent.cmake:1144` を**実際に開く**と `cmake_policy(VERSION 4.1)`。これは呼び出し時に既存の `CMAKE_POLICY_VERSION_MINIMUM` を検証する。つまり**誰かが途中で "3" に書き換えている**。
→ リポジトリ全体を grep しても誰も明示設定していない → 残る容疑者は「`cmake_minimum_required(VERSION <3.5)` の互換シム」。CMake 4.x はこのシムを通すと内部変数を **"3"** に汚染する。
→ **対処**: 汚染源（`glfw` の `3.0`、`tinyobjloader` の `3.2`）の宣言を **3.5 に引き上げ**、シムを発動させない。

**学べること**: エラーが指すファイル/行を**必ず開いて読む**。`-D` で渡したのに値が違う＝「後から上書きされている」と推理し、容疑者を grep で絞る。

### 4.2 Debug構成だけ `stdext` で落ちる理由

```
use of undeclared identifier 'stdext'   (fmt の make_checked / checked_ptr)
```
ReleaseのCLIビルドは通り、VS GUIのDebugだけ落ちた。
→ **差分に注目**: Release vs Debug。同梱fmtの該当箇所は `#if defined(_SECURE_SCL) && _SECURE_SCL`。**Debugでは `_SECURE_SCL`/`_ITERATOR_DEBUG_LEVEL` が非0**になり、`stdext::checked_array_iterator` を使う枝に入る。だが**VS 2026の新MSVC STLはこの型を削除済み**。
→ **対処**: その枝を無効化し、通常ポインタ経路に固定（チェック済みイテレータは警告抑制用で機能は同じ）。

**学べること**: 「ある構成だけ落ちる」→ その構成で変わるマクロ（`_DEBUG`/`NDEBUG`/`_ITERATOR_DEBUG_LEVEL`/`_SECURE_SCL`）を疑う。新STLは古い拡張を削除していることがある。

成果物: `build_vs/Piccolo.slnx`（Platform=ARM64, Toolset=ClangCL）。`.slnx` は新しいXML形式なので `*.sln` のグロブには引っかからない点に注意。

### 4.3 生成方法をリポジトリに固定する ── `CMakePresets.json`

上の `.slnx` を作る `-G "Visual Studio 18 2026" -A ARM64 -T ClangCL ...` を**毎回手で打つのは再現性が無い**。生成設定（ジェネレータ/アーキ/ツールセット/キャッシュ変数）は **`CMakePresets.json`** に書いてリポジトリに入れるのが正解。CMake公式機構で、**VS 2026 は「フォルダーを開く」でこのプリセットを直接認識**する。

リポジトリ直下の `CMakePresets.json` に configure プリセット `vs2026-arm64` を定義（`generator`/`architecture: ARM64`/`toolset: ClangCL`/`binaryDir: build_vs`）。これで:
```powershell
cmake --preset vs2026-arm64                 # build_vs\Piccolo.slnx を生成
cmake --build --preset vs2026-arm64-release # まとめてビルド
```
あるいは VS で**フォルダーを開く → プリセット `vs2026-arm64` を選択**。

**libclang の自動解決**: 手動の `-DPICCOLO_ARM64_LIBCLANG_DIR` を不要にするため、`meta_parser/CMakeLists.txt` を改修し **VSジェネレータが設定する `CMAKE_GENERATOR_INSTANCE`（=VS導入ルート）から `VC/Tools/Llvm/ARM64` を導出**するようにした（フォールバック順: `PICCOLO_ARM64_LIBCLANG_DIR` → `CMAKE_GENERATOR_INSTANCE` → `$ENV{VCINSTALLDIR}`）。これでプリセットは**追加フラグ無し・開発者環境無し**で動く。

**学べること**: 「動かすための呪文（生成コマンド）」は会話やシェル履歴に置かず、**`CMakePresets.json` でリポジトリに固定**する。これが「CMakeからVSプロジェクトを生成できる」状態。マシン固有の絶対パスはプリセットに直書きせず、**ジェネレータ提供の変数（`CMAKE_GENERATOR_INSTANCE`）**から導出して可搬性を保つ。

### 4.4 CMake GUIで`__builtin_shufflevector`が未定義になる

症状:

```text
'__builtin_shufflevector': identifier not found
identifier "__builtin_shufflevector" is undefined
```

原因はARM64そのものではなく、**CMake GUIでツールセットを指定せず、MSVC
（生成プロジェクトでは`PlatformToolset=v145`）を選んだこと**です。この版のJoltは
ARM64経路で`__builtin_shufflevector`などのClangビルトインを直接使用します。
MSVCにはこのビルトインがないため、NEON用コードのコンパイルで失敗します。

確認方法:

```powershell
Select-String build_vs\CMakeCache.txt -Pattern `
  '^CMAKE_GENERATOR_PLATFORM','^CMAKE_GENERATOR_TOOLSET'
Select-String build_vs\engine\3rdparty\JoltPhysics\Build\Jolt.vcxproj `
  -Pattern '<PlatformToolset>'
```

誤った構成では`CMAKE_GENERATOR_TOOLSET`が空で、`Jolt.vcxproj`が`v145`になります。
正しい構成は`ARM64`と`ClangCL`です。

推奨する復旧手順:

1. CMake GUIで`File > Delete Cache`を実行する。生成先を変える場合は空のディレクトリを使う。
2. PowerShellから`cmake-gui --preset=vs2026-arm64`を実行する。
3. GUIで`Configure`、`Generate`を実行する。
4. 生成された`build_vs\Piccolo.slnx`をVisual Studioで開いてビルドする。

手動選択する場合は、Configureダイアログで次の3項目を必ず指定します。

| 項目 | 値 |
|---|---|
| Generator | `Visual Studio 18 2026` |
| Optional platform | `ARM64` |
| Optional toolset | `ClangCL` |

再発防止として、トップレベル`CMakeLists.txt`はARM64でclang-cl以外が選択された場合、
構成時に理由と復旧手順を表示して停止します。これにより、Visual Studioのビルド段階まで
進んで大量の`__builtin_shufflevector`エラーになることを防ぎます。

**2026年6月15日の再検証**: CMake GUIと同じ指定で新規生成したプロジェクトについて、
`CMAKE_GENERATOR_PLATFORM=ARM64`、`CMAKE_GENERATOR_TOOLSET=ClangCL`、
`Jolt.vcxproj`の`PlatformToolset=ClangCL`を確認しました。Release全体のビルドに成功し、
生成されたARM64版Editorでリサイズ、最大化、復元のスモークテストも完走しました。

---

## 5. 本番の難所 ── 移植後に出るランタイムバグのデバッグ

ビルドが通って起動しても、**実行時の挙動**で初めて出る不具合がある。ここが移植の本当の山。共通する診断法は「**症状 → データの流れを逆/順にたどる → 元環境との差分を問う**」。

### 5.1 リサイズで画面が歪む → ビューポート未更新

→ **たどり方**: 「リサイズ＝スワップチェーン再生成」なので `recreateSwapchain` / `createSwapchain` を読む。`m_scissor` と `m_swapchain_extent` は更新されるのに **`m_viewport` だけ初期化時(1回)のまま**だと気づく。
→ `m_viewport` の使用箇所を grep → 多数のパスが毎フレーム `getSwapchainInfo().viewport`(=`&m_viewport`) で動的ビューポートを設定。古いサイズのままなので歪む。
→ **対処**: `createSwapchain()` で `m_scissor` の隣で `m_viewport` も `m_swapchain_extent` に追従させる。

**学べること**: 「対になって更新されるべき状態」の片方だけ更新漏れ、は頻出バグ。`grep で代入箇所を全部洗う`→`使用箇所を洗う`のデータフロー追跡が武器。

### 5.2 リサイズで黒い帯（未描画領域）→ ドライバ差を見抜く

歪みを直した後に出た**別症状**。「拡大すると新領域が黒い」。
→ **たどり方**: 黒帯＝スワップチェーンが新サイズに**再生成されていない**疑い。リサイズ検知の仕組みを追うと、`windowSizeCallback` は `m_width/m_height` を記録するだけで再生成を呼ばず、`registerOnWindowSizeFunc` も誰も使っていない。**検知は `VK_SUBOPTIMAL_KHR`/`VK_ERROR_OUT_OF_DATE_KHR`（acquire/presentの戻り値）頼み**。
→ **元環境との差分**: 元のGPUドライバはリサイズで確実にSUBOPTIMALを返す。**AdrenoのWindows-on-ARMドライバは（特に拡大時に）返さないことがある** → 再生成されず黒帯。
→ **対処**: `prepareBeforePass()` 冒頭で `glfwGetFramebufferSize` と `m_swapchain_extent` を**毎フレーム明示比較**し、食い違えば即 `recreateSwapchain()`。再生成したフレームはその場で呼び出し元へ返し、古いフレーム処理を続行しない。ドライバ報告に依存しない堅牢化。

**学べること**: Vulkanの `VK_SUBOPTIMAL_KHR`/`OUT_OF_DATE` 依存は**移植で壊れやすい**。リサイズ検知は「OSのウィンドウイベント or 明示的サイズ比較」で**自前でも持つ**のが堅い。「特定ドライバだけ」の挙動はドライバ実装差を疑う。

### 5.3 白い半透明の矩形 ── 第1幕：未初期化GPUバッファ（シェーダから逆算）

→ **たどり方**: 選択中が `Emitter`(`ParticleComponent`) なのでパーティクルを疑い、**フラグメントシェーダ `particlebillboard.frag` を読む**:
```glsl
out_scene_color.w = texture(sparktexture, in_uv).r;   // αがテクスチャのr
```
→ 「スパークテクスチャの r が ~1.0 を返すと白い不透明矩形になる」と分かる。だがスカイボックスも同じHDRローダで正常 → 読込失敗説は弱い。
→ **コンピュート側を読む**: `counter.alive_count = m_num_particle`(>0) で初期から「生存粒子」がある前提。その粒子データ本体 `m_position_host_buffer` の生成箇所を読むと、**map→flush→unmap するだけで中身を書いていない**。未初期化のままデバイスバッファにコピーしていた。
→ **元環境との差分**: **Vulkanは新規バッファのゼロ初期化を保証しない**。元GPUはたまたまゼロ（size=0で不可視）、Adreno はゴミ（巨大サイズの白ビルボード）。
→ **対処**: map直後に `memset(mapped, 0, size)`。

**学べること（GPU移植の定番バグ）**:
- **「ゼロ初期化されたGPUメモリ」を当てにしてはいけない**。Vulkanは保証しない。元環境で動いていたのは偶然。
- 描画結果から原因を探す時は **シェーダを起点に「どの入力がこの色を生むか」を逆算** → その入力(バッファ/テクスチャ)の生成・初期化を追う、という順路が効く。

### 5.4 白い矩形ふたたび ── 第2幕：再生成した画像を同じフレームで読んでいた

第1幕の修正には、ビルボードが**実際に読む** `m_position_render_buffer`
（シェーダの `renderParticles[]`）のゼロ初期化も加えた。それでも最大化と復元を
繰り返すと白い板が戻った。未初期化バッファは実在したが、再発する現象には別の
決定的原因があった。

#### 切り分け

1. 最大化したまま40秒待つ: 再発しない。
2. 最大化と復元を繰り返す: 暫定ガードなしでは20回目に再発。
3. したがって「経過時間」ではなく「スワップチェーン再生成回数」に依存する。

この比較により、粒子寿命や通常の衝突計算ではなく、再生成フレームの順序へ調査対象を
絞れた。

#### 根本原因1: コピー元画像を `UNDEFINED` と宣言していた

`ParticlePass::copyNormalAndDepthImage()` は、描画済みの深度・法線画像を粒子衝突用画像へ
コピーする。その直前のバリアが、コピー元の `oldLayout` を毎回
`RHI_IMAGE_LAYOUT_UNDEFINED` としていた。

しかしメインカメラのレンダーパスが保証する最終レイアウトは次の通り。

| 画像 | 実際の最終レイアウト |
|---|---|
| 深度 | `DEPTH_STENCIL_ATTACHMENT_OPTIMAL` |
| G-Buffer法線 | `SHADER_READ_ONLY_OPTIMAL` |

Vulkanで `oldLayout=UNDEFINED` は「以前の内容を保持しなくてよい」という意味であり、
単なる「現在値が分からない」というワイルドカードではない。描画済み画像に指定すると、
コピー結果は未定義になる。ドライバやメモリ配置によっては内容が残って見えるため、
通常時は動き、リサイズ時だけ壊れるように見えていた。

対処:

- コピー元の `oldLayout` をレンダーパスの実際の最終レイアウトへ合わせる。
- コピー後の `srcAccessMask` は `TRANSFER_WRITE` ではなく `TRANSFER_READ` にする。
- 次の描画が行うAttachment read/writeに合わせて復帰先アクセスを設定する。

#### 根本原因2: `present` 後の再生成を粒子パスへ通知していなかった

フレーム順序は次のようになっていた。

```text
メイン描画をsubmit
present
  └ OUT_OF_DATE/SUBOPTIMALならスワップチェーンと深度・法線画像を再生成
粒子用に深度・法線をコピー
粒子シミュレーション
```

`present` 内で再生成した場合、直後のコピーが読むのは「今作ったばかりで、一度も描画
されていない画像」だった。これを粒子衝突へ渡すことで粒子位置が壊れ、カメラ至近の
小さなビルボードが薄い巨大矩形に見えていた。

対処:

- `RHI::submitRendering()` の戻り値を「present後に再生成したか」の `bool` に変更。
- 再生成したフレームでは `copyNormalAndDepthImage()` と `simulate()` を実行しない。
- 描画前の明示サイズ差で再生成した場合も、そのフレームを直ちに終了する。
- 再生成時はImageViewをImageより先に破棄し、Vulkanのオブジェクト寿命規則に合わせる。

#### 症状隠しを外して検証する

原因調査中には、投影サイズが大きい粒子を頂点シェーダで非表示にするガードと、衝突距離
クランプも試した。しかし、これらを残したままでは「原因が直った」のか「症状を隠した」
のか区別できない。最終検証前に両方を外し、元の粒子シェーダへ戻した。

当初の検証結果（Windows 11 ARM64、2026年6月15日）:

- ARM64 Debugビルド成功。
- Vulkan検証レイヤで、今回の画像レイアウト・破棄順に関するエラーなし。
- Debug版で最大化↔復元を30往復し、5往復ごとの画像を確認して再発なし。
- ARM64 Releaseビルド成功。
- Release版で最大化↔復元を20往復し、再発なし。

ただし、この「再発なし」は後続の連続起動テストで覆った。通常終了後に同じ実行ファイルを
再起動すると白い矩形を再確認できたため、上記はVulkanリサイズ処理の修正確認ではあっても、
白い矩形の根治確認ではない。再現頻度が低い不具合では、1種類の操作だけで根治を宣言しない。

**学べること（最重要級）**:

- `UNDEFINED` は「不明」ではなく「内容を破棄してよい」。コピー元には実レイアウトを書く。
- リソースを再生成したフレームは、後段処理まで含めて中止する。コールバックで作り直す
  だけでは、呼び出し元が古いフレーム処理を続けてしまう。
- 再現条件を「時間」と「操作回数」に分けると、状態遷移バグを短時間で絞り込める。
- 暫定ガードを外して再試験する。ガード付きの成功だけでは根治の証明にならない。

### 5.5 白い矩形ふたたび ── 第3幕：0インスタンス描画

x64機では発生せず、ARM64機では初回起動でも発生することがあったため、保存状態や
「2回目以降」という条件をいったん捨て、ARM64 GPU上で実際に発行される描画命令を調べた。

#### 発生源と描画数を別々に確認する

`ParticlePass::draw()` 全体を一時停止すると白い矩形が消えたため、粒子パスが発生源である
ことは確認できた。ただし、これだけでは「粒子データが壊れた」とは断定できない。

そこで描画直前の `m_num_particle` をログへ出した。白い矩形が明瞭に出ているフレームでも、
値は一貫して次の通りだった。

```text
Particle draw count: emitter=0, instances=0
```

RHIの引数順も確認した結果、実際に次の命令が記録されていた。

```cpp
vkCmdDraw(command_buffer, 4, 0, 0, 0);
```

Vulkan仕様上、`instanceCount == 0` は描画結果を生成しない。しかし本ARM64環境では、
この0インスタンス描画を発行した状態で白い矩形を再現した。実機ログは次の通り。

```text
Vulkan device: Microsoft Direct3D12 (Qualcomm(R) Adreno(TM) X1-45 GPU)
Vulkan queue families: graphics=0, present=0, compute=0
```

x64機では発生しないことも合わせると、Qualcomm ARM64のVulkan/D3D12経路における
ドライバ互換性問題が強く示唆される。ドライバ内部の欠陥箇所まではプロジェクト側から
証明できないため、ここでは「白い矩形を発生させる直接トリガーは0インスタンスの
`vkCmdDraw`」までを確認済みの根本原因とする。

#### 修正

描画対象が0個なら、粒子パイプラインのbindや `vkCmdDraw` を記録しない。

```cpp
for (int i = 0; i < m_emitter_count; ++i)
{
    if (m_emitter_buffer_batches[i].m_num_particle == 0)
    {
        continue;
    }

    // pipeline / descriptor bind
    m_rhi->cmdDraw(...);
}
```

これは見た目を隠すシェーダガードではない。実行しても結果がない描画命令をCPU側で除外し、
問題を起こすドライバ経路へ入らないようにする修正である。

#### 途中で判明した別問題

- 粒子フラグメントシェーダは粒子のαを無視していたため、αを反映し `0..1` へ制限した。
- 発生タイマーを256スレッドから非アトミック更新していたため、1スレッドのkickoff処理へ
  移した。
- `Vector2` の各要素には元から `{0.f}` のメンバ初期化子があり、デフォルト構築でも
  ゼロ初期化される。「`Vector2()` はゼロ初期化しない」という旧仮説は誤りだった。

これらは独立した品質修正だが、今回の白い矩形の直接原因ではなかった。根本原因と
ハードニングを混同しない。

#### 最終検証（Windows 11 ARM64、2026年6月15日）

- ARM64 Debugビルド成功。
- 修正前: 最大化状態で10秒、30秒、60秒の全時点に白い矩形を再現。同じ実行中、
  粒子インスタンス数は0。
- 修正後 Debug: 新規起動を5回、各15秒最大化し、全5回で再発なし。
- 修正後 Debug: 同一プロセスで最大化と復元を10往復し、その後30秒・60秒時点でも
  再発なし。
- ARM64 Releaseビルド成功。
- 修正後 Release: 新規起動を3回、各15秒最大化し、全3回で再発なし。

Debug実行時には、キューブマップ転送に関する既知の検証レイヤ警告
`VUID-vkCmdCopyBufferToImage-imageOffset-07738` が残る。今回の0インスタンス描画とは
別件であり、「検証レイヤ警告が0件」とは記録しない。

#### 再現確認の要点

1. タイトルが `Piccolo - N FPS` になるまで待つ。
2. 最大化して最低15秒待ち、スクリーンショットを保存する。
3. 通常終了後、同じ実行ファイルを5回以上起動する。
4. 単発起動だけでなく、最大化と復元を10往復する。
5. 発生時は描画パスの有無だけでなく、実際のvertex/instance数も記録する。

---

## 6. 何度でも効く「汎用原則」まとめ

このプロジェクトで得た、**他の移植でもそのまま使える**教訓:

### 移植の段取り
- まず**エミュ等で動く基準**を作り、コード問題とアーキ問題を分離する。
- **同梱バイナリの棚卸し**（アーキ判定）で戦う相手を最初に確定する。
- 設定を変えたら**生成物(build.ninja等)を grep**して効果を確認する。

### ツールチェーン
- 新しすぎ/古すぎのCMakeは衝突する。**ジェネレータ依存を外す(Ninja)** か **時代の合うCMakeを用意**。
- 上流ライブラリがMSVC非対応 → **clang-cl への切替**で回避できることがある（MSVC ABI互換 + Clang機能）。手動修正のコストが高い時の有力カード。
- 不足ライブラリは**ダウンロード前に VS/SDK 同梱を探す**。C APIは後方互換が効きやすい。
- ターゲットアーキ判定は `CMAKE_CXX_COMPILER_ARCHITECTURE_ID`。迷ったら**プローブCMakeで実測**。

### Vulkanの「未定義だが動いてしまう」依存（移植で壊れる）
- **バッファのゼロ初期化は保証されない** → 明示的に初期化する。
- `oldLayout=UNDEFINED` は内容破棄の許可。描画済みのコピー元には**実際のレイアウト**を書く。
- **`VK_SUBOPTIMAL_KHR`/`OUT_OF_DATE` の報告はドライバ依存** → リサイズは自前のサイズ比較でも検知する。
- 対で更新すべき状態（viewport/scissor/extent等）の**更新漏れ**に注意。
- 再生成したフレームでは、作り直した画像を読む後段パスを実行しない。
- リサイズで壊れるのは描画だけではない。深度・法線を読むコンピュートも、未描画の再生成画像で異常動作する。

### デバッグ姿勢
- エラーが指す**ファイル・行・ヘッダを実際に開く**。
- 「**ある構成/GPU/コンパイラだけ**」失敗 → その差分（マクロ、ドライバ、STL版）を疑う。
- 描画バグは**シェーダ出力から入力へ逆算**する。
- **最初の修正で症状が消えなければ、仮説は部分的**。観測事実に戻って仮説を更新する（直した気にならない）。
- **確率的バグと決定的バグを区別**する。「ほぼ確定」「特定操作で再現」は決定的＝状態/ロジック原因。確率的原因（未初期化メモリ等）に固執しない。
- **定量で原因空間を狭める**（粒子サイズと画面占有率から至近距離を逆算する、等）。
- 症状を隠すガードを試した場合は、根本修正後に外して再試験する。

---

## 7. 再現用コマンド早見表

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$cmake = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

# --- VS 2026 ソリューション（ARM64 / ClangCL）---
& $cmake --preset vs2026-arm64
& $cmake --build --preset vs2026-arm64-release --parallel 8
& $cmake --build --preset vs2026-arm64-debug --parallel 8

# --- CMake GUIを使う場合 ---
cmake-gui --preset=vs2026-arm64
# IDEで開くのは build_vs\Piccolo.slnx。VSで「フォルダーを開く」→プリセット選択でも可。

# --- バイナリのアーキ判定（1.2参照）---
# Arch 関数を定義して: Arch ".\bin\PiccoloEditor.exe"  → ARM64 を確認
```

ポイント:
- 通常の再現とIDE利用には`build_vs`だけを使う。x64/Ninjaによる原因切り分けを行う場合は別のビルドディレクトリを使い、混ぜない。
- `CMakePresets.json`がジェネレータ、ARM64、ClangCL、出力先を固定するため、手入力の`-A`や`-T`は不要。
- ソースのみ変更時は再構成不要、増分ビルドでよい。

---

## 8. 変更ファイルと対応表

| 目的 | ファイル |
|---|---|
| ターゲットARM64判定 | `CMakeLists.txt` |
| Vulkan ARM64分岐 | `engine/CMakeLists.txt` |
| libclang ARM64自動解決 | `engine/source/meta_parser/CMakeLists.txt` |
| Jolt PCH/SIMD/警告/リンカ対応 | `engine/3rdparty/JoltPhysics/Jolt/Jolt.cmake`, `engine/3rdparty/JoltPhysics/Build/CMakeLists.txt` |
| chronoリテラル | `engine/3rdparty/JoltPhysics/Jolt/Core/JobSystemThreadPool.cpp` |
| CMake 4.x互換 | `engine/3rdparty/glfw/CMakeLists.txt`, `engine/3rdparty/tinyobjloader/CMakeLists.txt` |
| 新MSVC STL互換 | `engine/3rdparty/spdlog/include/spdlog/fmt/bundled/format.h` |
| ビューポート更新 + 明示的リサイズ検知 + 再生成通知 | `engine/source/runtime/function/render/interface/rhi.h`, `engine/source/runtime/function/render/interface/vulkan/vulkan_rhi.h`, `engine/source/runtime/function/render/interface/vulkan/vulkan_rhi.cpp` |
| 再生成フレームの粒子処理中止 | `engine/source/runtime/function/render/render_pipeline.cpp` |
| パーティクルバッファ初期化 + 深度/法線コピーのレイアウト修正 | `engine/source/runtime/function/render/passes/particle_pass.cpp` |
| 粒子発生タイマーの初期化 + GPU競合解消 | `engine/source/runtime/function/particle/particle_desc.h`, `engine/shader/glsl/particle_kickoff.comp`, `engine/shader/glsl/particle_emit.comp` |
| 粒子α反映 + HDR値のαクランプ | `engine/shader/glsl/particlebillboard.frag` |
| VSプロジェクト生成プリセット | `CMakePresets.json` |

---

## 付録: つまずいたら見るチェックリスト

- ビルドが通らない → エラーの**最初の1件**を、指す**ファイル/行を開いて**読む。ツールの新旧衝突を疑う。
- リンクで「アーキ不一致」 → 同梱 `.lib` のアーキを判定。ターゲットと一致しているか。
- 「特定構成だけ」失敗 → `_DEBUG`/`NDEBUG`/`_ITERATOR_DEBUG_LEVEL`/`_SECURE_SCL` を疑う。
- 「特定GPUだけ」描画がおかしい → 未初期化バッファ / ドライバの戻り値依存 / 拡張サポート差 を疑う。
- 描画が変 → **シェーダ出力から入力へ逆算** → その入力の生成・初期化コードへ。
- 半透明素材が板状に見える → テクスチャαと頂点/粒子αの両方が最終出力へ反映されているか、HDR値をαへ直接使っていないか確認する。
- **修正したのに症状が残る** → 仮説が部分的。出方（確率的か決定的か、特定操作で再現するか）を見極め、**定量（サイズ・距離・画面占有率）で仮説を絞り直す**。
- 「**特定操作（最大化等）でほぼ確定**」 → 確率的原因ではなく**リサイズ/状態整合性**を疑う。再生成したフレームが後段処理を続けていないか、コピー元の実レイアウトとバリア指定が一致するかを洗う。
- 設定変更が効かない → `-D`値が後から上書きされていないか（互換シム等）。**生成物を grep**して実値を確認。
