# 阮·梅桌宠 · macOS

一个常驻桌面的原生小挂件：形象来自阮·梅立绘（已去白底），会呼吸、轻轻浮动、眨眼、飘落花瓣；可以拖到屏幕任意位置；每到整点用文字气泡 + 语音提醒你喝水。

![预览](docs/preview.png)

> 这是独立的 macOS 原生应用，不是浏览器插件。浏览器/网页插件无法把内容覆盖到「所有应用」之上，只有原生窗口（`NSPanel`）才能做到。

> 本仓库是 **v3.4 发布快照**：包含源码、构建脚本、处理后的形象/眨眼/语音资源与预览；原始录屏和未处理立绘未随仓库提供。

## 下载

- [GitHub Releases](https://github.com/wcwww-del/ruanmei-desktop-pet/releases/latest) 下载 `RuanMeiPet-v3.4-macOS.zip`（macOS 13+，Apple Silicon）
- 解压后双击 `阮·梅桌宠.app`；首次打开如被 Gatekeeper 拦截，右键 →「打开」
- 也可以 clone 仓库后运行 `./build.sh` 自行构建

## 直接运行

从 [Releases](https://github.com/wcwww-del/ruanmei-desktop-pet/releases/latest) 下载 zip，解压后双击 `阮·梅桌宠.app`；首次打开如果被 Gatekeeper 拦下，右键 →「打开」。

本地构建后也可以：

```bash
open "dist/阮·梅桌宠.app"
```

启动后没有 Dock 图标，控制入口在**菜单栏右上角的水滴图标**，右键阮·梅也能打开同一个菜单。

## v3.4 更新（当前版本）

- 菜单顶部标题从「阮·梅 · 桌宠」改为「阮·梅桌宠」。
- 删除「试听喝水语音」菜单项。
- 新增全局「语音」开关：关闭后所有语音（喝水、打招呼、移动、点击 1/2/3）静音，但气泡仍然显示；重新打开即恢复。开关状态会记住。

## v3.3 更新

- **移动结束语音**：拖动阮·梅松手后，气泡显示「很好，优美的姿势。」并播放 `ruanmei_move.m4a`。
- **点击分级语音**：
  - 单击一次 →「那是什么？有点…感兴趣。」（点击语音包 1）
  - 1 秒内连点 2 次 →「有趣吗？」（点击语音包 2）
  - 1 秒内连点 3 次及以上 →「离我远点。」（点击语音包 3）
- 气泡与对应语音完全一致；移动、点击、打招呼、整点提醒的语音互斥，开始播放一个会停掉前一个。
- 新增 4 条音轨：`ruanmei_move.m4a`、`ruanmei_click1/2/3.m4a`。

## v3.2 更新

- 整点喝水气泡固定为与语音完全一致的「休息一下，茶点时间到了。」；菜单「现在提醒我喝水」也使用同一句。
- 打招呼语音保持 v3.1 的行为，不受影响。

## v3.1 更新

- **新增「打招呼」语音**：从 `阮·梅打招呼语音包.MP4`（6.87 秒）提取 `assets/ruanmei_greet.m4a`（6.85 秒）。
- 菜单栏 →「打个招呼」：播放这段语音，气泡同步显示「我叫阮·梅，念我名字时，请别忘了中间气息的停歇。」
- 打招呼语音与整点喝水语音互斥：开始播放其中一个时，会先停掉另一个。

## v3.0 更新

按反馈做了减法：

- **只保留眨眼**：约 0.2 秒一次，随机 3–6.8 秒触发，偶尔连眨两下。推眼镜、发丝飘动、喝水动作及对应的手部/水杯/发丝序列全部移除。
- **重新提取语音**：从新版 `阮·梅语音包.MP4`（3.99 秒）重新提取，覆盖了原来的 `assets/ruanmei_voice.m4a`（3.98 秒）。整点提醒时气泡 + 语音一起出现。
- 保留 v1 的呼吸、浮动、摇摆、点击弹跳、花瓣/星光/水滴粒子，以及 230 pt 的小尺寸。
- App 体积从 v2 的 12 MB 回到约 **2.3 MB**。

## 怎么玩

| 操作 | 效果 |
| --- | --- |
| 按住她拖动 | 随意移动；松手后位置会被记住，并说「很好，优美的姿势。」 |
| 单击 | 说「那是什么？有点…感兴趣。」（点击语音 1） |
| 1 秒内连点 2 次 | 说「有趣吗？」（点击语音 2） |
| 1 秒内连点 3 次及以上 | 说「离我远点。」（点击语音 3） |
| 右键 | 打开菜单 |
| 点击气泡 | 关闭气泡 |
| 菜单栏水滴 | 大小 / 整点提醒 / 夜间免打扰 / 语音（总开关） / 始终置顶 / 隐藏 / 重置位置 / 退出 |

透明区域不会拦截鼠标，不会挡住下面窗口的点击。

## 整点喝水提醒

- `ReminderScheduler` 每秒对时，`xx:00` 触发，按「年-月-日-时」去重。
- 提醒 = 文字气泡 + 跳一下 + 水滴粒子 + **语音**。
- 气泡固定为与语音一致的「休息一下，茶点时间到了。」。
- 菜单可关闭提醒；可开启 **23:00–07:00 夜间免打扰**。
- 语音提取命令（需要本地原始 MP4 素材；本仓库只包含提取后的 m4a）：

```bash
afconvert -f m4af -d aac -b 128000 "阮·梅语音包.MP4" assets/ruanmei_voice.m4a
afconvert -f m4af -d aac -b 128000 "阮·梅打招呼语音包.MP4" assets/ruanmei_greet.m4a
afconvert -f m4af -d aac -b 128000 "阮·梅移动语音包.MP4" assets/ruanmei_move.m4a
afconvert -f m4af -d aac -b 128000 "阮·梅点击语音包1.MP4" assets/ruanmei_click1.m4a
afconvert -f m4af -d aac -b 128000 "阮·梅点击语音包2.MP4" assets/ruanmei_click2.m4a
afconvert -f m4af -d aac -b 128000 "阮·梅点击语音包3.MP4" assets/ruanmei_click3.m4a
```

喝水语音内容是「休息一下，茶点时间到了。」，整点气泡也使用完全相同的这句话。打招呼语音内容是「我叫阮·梅，念我名字时，请别忘了中间气息的停歇。」，点击「打个招呼」时气泡显示同一句。

想换语音，替换 `assets/` 下对应的 `.m4a` 后重新构建，或放到 `~/Library/Application Support/RuanMeiPet/` 覆盖。菜单栏 →「语音」可以一键开关所有声音；打招呼语音直接点「打个招呼」。

## 换成别的形象

优先级从高到低：

1. `~/Library/Application Support/RuanMeiPet/ruanmei.png`
2. App 包内 `Contents/Resources/ruanmei.png`
3. 源码目录 `assets/ruanmei.png`

放一张**透明底、正方形 PNG**，重启应用即可。非正方形会按比例适配，但眨眼叠加层是按这张图设计的，换图后位置可能对不上。

重新处理原始图（需要未处理的 `阮·梅.png`，未随仓库提供）：

```bash
python3 tools/process_assets.py     # 去白底、裁切、应用图标
python3 tools/make_effects.py       # 眨眼叠加层、柔和投影
./build.sh
```

## 构建

```bash
./build.sh
```

- 需要 Xcode Command Line Tools（`swiftc`、`iconutil`）
- 目标：macOS 13+，当前为 Apple Silicon（arm64）
- ad-hoc 签名，只在本机使用；拷到别的 Mac 如被拦截，右键 →「打开」

## 目录结构

```
assets/ruanmei.png            去白底后的 900×900 形象（运行所需）
assets/fx_blink_half.png      半闭眼叠加层
assets/fx_blink_closed.png    闭眼叠加层
assets/fx_shadow.png          柔和投影
assets/ruanmei_voice.m4a      喝水提醒语音（3.98s）
assets/ruanmei_greet.m4a      打招呼语音（6.85s）
assets/ruanmei_move.m4a       移动结束语音（3.80s）
assets/ruanmei_click1.m4a     点击语音 1（5.21s）
assets/ruanmei_click2.m4a     点击语音 2（3.23s）
assets/ruanmei_click3.m4a     点击语音 3（2.75s）
Sources/                      原生 AppKit 源码
  PetView.swift               动画、眨眼、粒子、气泡、拖拽
  PetEffects.swift            形象与眨眼/阴影资源加载
  PetController.swift         窗口、菜单栏、提醒、位置记忆、语音
  PetPanel.swift              透明置顶面板
  ReminderScheduler.swift     整点调度
  Support.swift / Snapshot.swift
tools/                        资产生成脚本
dist/                         本地构建产物（不随仓库提交）
docs/preview.png              效果预览（真实运行截图合成）
```

> 原始立绘与游戏录屏未包含在仓库中；`assets/` 里是运行所需的成品图片、眨眼图层和提取后的语音。

## 版本

- `v1.0`：置顶、拖拽、整点喝水气泡、基础动效。
- `v2.0`：眨眼、发丝飘动、推眼镜、喝水动作、整点语音、尺寸缩小到 230。
- `v3.0`：按反馈移除推眼镜/发丝/喝水，只保留眨眼；重新提取语音；体积回到 2.3 MB。
- `v3.1`：新增「打个招呼」语音（初次见面），气泡与语音同步。
- `v3.2`：整点喝水气泡改为与语音完全一致的「休息一下，茶点时间到了。」。
- `v3.3`：移动结束语音 + 点击 1/2/3 分级语音，气泡与语音一致。
- `v3.4`：菜单标题改为「阮·梅桌宠」；删除试听项；新增全局语音开关。

## 已知边界

- 锁屏/登录窗口之上不会显示（系统安全限制）
- 通知气泡由应用自身绘制，不经过通知中心；不需要通知权限
- 整点提示在系统睡眠期间不会补发；唤醒后从下一个整点继续
- 应用不常驻 Dock，退出请用菜单栏 →「退出阮·梅」
- 形象与语音版权归 miHoYo / HoYoverse，仅作个人桌面装饰使用
