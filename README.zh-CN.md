# SACD for Lyrion Music Server（中文说明）

![GitHub Release](https://img.shields.io/github/v/release/BeyondandSharp/lms-plugin-sacd)

[English README](README.md)

`SACD` 插件为 LMS 9.0+ 增加面向 SACD 的 DSF/DFF 支持（已在 9.0.0 与 9.1.1 上测试）：

- 扫描 `.dsf` 和 `.dff`，包括 DST 压缩的 DSDIFF；
- 只读取文件头/元数据块来获取标签和封面，不解码整个文件；
- 支持输出 **PCM/FLAC**、**DoP**（DSD over PCM）或 **Native DSD**；
- 当播放器或 helper 不支持所选模式时，自动回退到 PCM。

结构参考了
[plugin-DSDPlayer](https://github.com/LMS-Community/plugin-DSDPlayer)，
但额外实现了 DST 头解析和有界标签读取。

## 环境要求

- Lyrion Music Server **9.0+**（测试目标：9.0.0 与 9.1.1）。
- PCM/FLAC 路径需要 **FFmpeg 7.1+**，有 `ffmpeg` 可执行文件即可。
  官方 `lmscommunity/lyrionmusicserver` 镜像**不自带 ffmpeg**：
  PCM 模式需要另外安装，Native DFF/DoP DST 只需插件内置 helper。
- `Audio::Scan >= 0.94`（LMS 9.0+ 自带）。
- Native DSD/DoP 需要编译 `helper/src` 下的 `sacd_dsd`。
- DST Native/DoP 使用内置的 **libdstdec**，不需要特殊的 FFmpeg 构建；
  libdstdec 处理 DSD64、DSD128 和 DSD256 DST。

## 安装

1. 使用打包后的 `dist/SACD` 目录（或 release ZIP/tar.gz），复制到
   LMS 的 `Plugins/SACD`。源码树里只有 `install.xml.in`，必须先
   `make dist` 才能直接安装。
2. 编译 helper：
   ```sh
   sudo apt-get install build-essential
   make -C helper/src
   make -C helper/src install
   ```
   这会生成 `Bin/x86_64-linux/sacd_dsd`（或对应架构）。helper 已包含
   libdstdec，因此 DST Native/DoP 不需要 FFmpeg 开发头文件。
3. 重启 LMS，在 **设置 > 插件** 中启用 SACD。
4. 打开插件设置查看 FFmpeg/helper 状态，再在播放器设置中选择输出模式。

helper 也可以放到 `PATH`；插件设置页支持填写绝对路径。

## Docker 安装路径

官方 Docker 镜像 `lmscommunity/lyrionmusicserver` 的第三方插件目录是：

```text
/config/cache/Plugins
```

不是 `/config/Plugins`。可以复制：

```sh
docker cp dist/SACD <容器>:/config/cache/Plugins/SACD
```

或只读挂载：

```sh
-v /path/to/dist/SACD:/config/cache/Plugins/SACD:ro
```

修改插件后建议同时删除缓存并重启：

```sh
docker exec <容器> rm -f /config/cache/plugin-data.yaml
docker restart <容器>
```

## 输出模式

| 模式 | 输出 | 说明 |
|---|---|---|
| PCM | 通过 FFmpeg 输出 24-bit FLAC | 默认模式。DSD64 → 352.8 kHz；更高 DSD 率最高降到 352.8 kHz，并受播放器支持范围限制。 |
| DoP | DSD/16 的 24-bit PCM WAV | 位完美的 DSD 传输；DAC 必须支持 DoP。默认上限 DSD128，可配置为 DSD64/128/256。 |
| Native | helper 输出 DFF 原始 DSD | 播放器必须报告支持 `dff`。DST 需要 helper 的 `dst_native=1`，否则回退 PCM。Squeezelite 和没有 ffmpeg 的 Docker 环境推荐此模式。 |

DoP 不是 Native DSD：它把 DSD 数据放进 24-bit PCM 样本中，并带 DoP
marker。helper 使用 WAV 容器，让 LMS/播放器在 LMS 9.0/9.1 这种没有逐流
采样率 hook 的版本上也能看到正确的 DSD/16 采样率。

> 注意：Squeezelite 的 HELO 通常只列出 `aif,pcm` 等格式，不一定报告
> `wav`，因此它的 DoP 选项可能显示为不可用；这种情况请使用 Native DSD。

`SACD` 插件只负责**解码**：把 DSD/DST 转成无损 FLAC 或裸 PCM，从不定义
最终的 AAC/Ogg Vorbis/Opus 有损 profile。需要这类目标格式时，由
`CodecSwitch` 组合管线（`DSD -> FLAC/PCM -> 目标格式`），再由 `FFmpeg`
完成编码。

## 解码能力接口（CodecSwitch / FFmpeg 集成）

编排层可以通过两个可选方法获取本插件的解码能力和可直接使用的解码命令。
未安装 CodecSwitch 时调用这两个方法也是安全的，并且不会影响独立播放：

- `Plugins::SACDPlayer::Transcoder->codec_capabilities($client)` 返回：

  ```perl
  {
      provider => 'sacd',
      priority => 50,
      decode   => [
          { from => [qw(dff dsf)], to => ['flc'], scope => ['local'] },
          { from => [qw(dff dsf)], to => ['pcm'], scope => ['local'],
            pcm  => { sample_fmt => 's16le', rate => 44100, channels => 2 } },
      ],
      encode   => [],
  }
  ```

- `Plugins::SACDPlayer::Transcoder->decode_plan($client, $format, $opts)`
  返回 `{ command, capabilities, format }`；当格式不是 DSD 解码目标
  （例如 `aac`、`ogg`、`ops`）时返回 `undef`。
  - `$format = 'flc'`：复用 FFmpeg 的 FLAC 输出命令（`-f flac -`）。
  - `$format = 'pcm'`：输出无容器的裸 little-endian PCM。
    `$opts` 支持 `sample_fmt`（`s16le` 或 `s24le`，默认 `s16le`）、
    `rate`（默认 `44100`）和 `channels`（默认 `2`）。
  - `command` 是 LMS profile 风格命令，包含 `$FILE$`、`$START$`、`$END$`、
    `$RESAMPLE$` 占位符；`capabilities` 是 LMS capability hashref
    （`F`、`T`、`U`、`D`）。

示例：

```perl
my $plan = Plugins::SACDPlayer::Transcoder->decode_plan(
    $client, 'pcm', { sample_fmt => 's16le', rate => 48000, channels => 2 },
);
my $command = $plan->{command} . ' | ' . $encoder_command;
```

## 标签读取

- **DSF**：`Audio::Scan` 读取 80 字节文件头并定位 ID3；不可用时插件
  自己解析文件头和 ID3。
- **DFF/DSD**：解析 `FRM8`、`PROP`、`DIIN`、`ID3` 块，并跳过 `DSD ` 音频数据。
- **DFF/DST**：Audio::Scan 不支持 DST；插件解析 `FRTE` 获得时长，跳过
  `DSTF` 帧头，不会读取整个 DST 数据。ID3/DIIN 标签从有界块读取。
- `ffprobe` 仅作为文件头/元数据解析失败时的后备，使用
  `-probesize 5000000 -analyzeduration 2000000`。

`t/01-tag.t` 会解析合成的 DST 文件、读取 ID3 并从 `FRTE` 计算时长，
不读取 `DSTF` 负载。

## 与 DSDPlayer 冲突

两个插件都会替换 `dsf`/`dff` 的标签读取器。请只启用其中一个。若同时启用，
SACD 插件会记录警告；最后加载的插件生效。SACD 插件额外支持 DST 和更多
输出模式。

## 已知限制

- **不支持 SACD ISO（`.iso`）**。需要虚拟曲目或解包缓存设计，属于后续阶段。
- Native/DoP DST 使用内置 **libdstdec**，支持 **DSD64、DSD128 和 DSD256 DST**
  （DSD64 是 SACD 格式）。DSD256 使用相同的 75 fps 帧结构和 libdstdec 的
  18816 字节上限；目前还没有真实 DSD256 DST 文件实测。许可证和来源见
  `THIRD_PARTY_NOTICES.md`。
- Native DST 的定位会从头解码并丢弃前面的数据；结果正确，但不是瞬时定位。
- 多声道会原样输出，但播放器/DAC 必须支持对应声道数。
- 初始验证以 Linux 为主；Windows 构建不在初始验证范围内。

## 预编译/打包目录

插件本身是 Perl（LMS 加载 Perl 模块），但架构相关的 helper 是原生二进制。
要生成可直接部署的目录：

```sh
make dist
```

生成：

```text
dist/SACD/
├── install.xml
├── lib/                 # 插件 Perl 模块
├── HTML/                # 设置页面
├── strings.txt
├── Bin/x86_64-linux/sacd_dsd   # 另有 aarch64/armhf/arm/i386/Windows
├── README.md
├── README.zh-CN.md
├── THIRD_PARTY_NOTICES.md
└── LICENSE
```

把整个 `SACD` 目录复制到 LMS。安装目录名是 `SACD`；Perl 模块仍保留历史名称 `Plugins::SACDPlayer`，LMS 会从 `install.xml` 读取该模块：

```sh
cp -a dist/SACD /path/to/lms/Plugins/SACD
```

默认 `make dist` 使用静态链接的 helper，并包含 libdstdec，因此 DSD64/128/256
DST 的 `dst_native=1`，LMS 主机不需要编译器或 FFmpeg 开发头文件。

`make install PLUGINS_DIR=/path/to/lms/Plugins` 可直接复制该目录。
`make bundle` 生成当前架构的包；`make bundle-all` 会构建全部支持的 Linux
架构并生成 `dist/SACD-<version>-all.tar.gz`。

### 支持的 helper 架构

```text
x86_64-linux
aarch64-linux
armhf-linux
arm-linux
i386-linux
MSWin32-x64-multi-thread
```

`make bins` 构建全部支持的目标到 `Bin/`；`make verify-bins` 用 `file` 和
QEMU/Wine 检查。Debian 上交叉编译还需要匹配的 `libc6-dev-*-cross`
头文件包（编译器只把它们列为 Recommends）。发布 CI 使用 `bundle-all`，因此发布包会包含全部目标。
不支持 macOS（`darwin`）。

## 版本号管理

仓库只维护一个版本号来源：

```text
VERSION
```

真正带版本号的 `install.xml` / `repo.xml` **不提交到仓库**。仓库里只有
模板：

```text
install.xml.in   # <version>@VERSION@</version>
repo.xml.in      # version="@VERSION@" / @RELEASE_URL@
```

发布新版本时执行：

```sh
make bump VERSION=0.3.1
```

该命令会更新 `VERSION`，并在构建时渲染：

- `build/install.xml`
- `build/repo.xml`
- helper 下一次编译时的 `--probe` 版本号

`make dist` / `make bundle` 会自动渲染这些文件。
Forgejo 发布时 workflow 会把 tag 版本传给 `make bundle VERSION=...`。
默认下载地址基址和 tag 前缀可通过 `RELEASE_BASE=...`、
`RELEASE_TAG_PREFIX=...` 覆盖。

只生成插件目录的 catalog 文件：

```sh
make repo
# -> build/repo.xml
```

## 开发

```sh
make -C helper/src
prove -l -It/lib t
make -C helper/src test
```

插件模块在 `lib/Plugins/SACD/`，helper 在 `helper/src/`。

主要文件：

- `lib/Plugins/SACD/TagReader.pm` – 有界元数据读取。
- `lib/Plugins/SACD/DFFParser.pm` – DSDIFF/DFF 块解析（支持 DST）。
- `lib/Plugins/SACD/ID3.pm` – 精简 ID3v2/封面解析。
- `lib/Plugins/SACD/Transcoder.pm` – LMS 转码命令配置。
- `lib/Plugins/SACD/Hooks.pm` – 采样率和格式选择 hook。
- `helper/src/sacd_dsd.c` – DoP 打包器和 DFF 写入器。

## 许可证

插件和 helper 采用 GPL-2.0-or-later；内置 libdstdec 的许可证和来源见
`THIRD_PARTY_NOTICES.md`。
