# PosterCard

一部片的入口：海报、角标、片名、来源。首页、分类、搜索结果、「我的」都用它。

**用在**：所有片单。一行里的海报一样宽，宽高比 `poster-ratio`（站点 `style` 另有规定时按站点）。

**使用方提供**：海报地址（可能没有）、片名、角标文字（「更新至 21 集」「HD」，可空）、次要信息（站点名或年份，可空）、点按时做什么、长按 / 菜单键时做什么（可空）。

**规则**
- 海报圆角 `radius-poster`；没加载出来时是 `poster-empty`，不画转圈。
- 角标在海报左下，`caption` 字号，`scrim` 底、白字，圆角 `radius-xs`。只放一条，不叠多个。
- 片名 `title`、一行省略；次要信息 `body-sm` 配 `ink-muted`。
- 悬停：上浮 2px 加 `shadow-lift`。电视焦点：放大到 1.06、`focus` 焦点框、`shadow-focus-glow`，片名变 `accent-ink`。
- 不在海报上放按钮；收藏、下载这些放到详情页或长按菜单里。

**在 Flutter 里**：`PosterCard`。
