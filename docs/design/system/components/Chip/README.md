# Chip

小块的选择：筛选条件、线路、选集。

**用在**：分类页的年份 / 类型筛选，搜索结果按站点筛，详情页和播放器面板里的线路与选集。

**使用方提供**：文字、可选的数量（如站点的结果数）、是否选中、点按时做什么。选集另外提供：是否看过、是否正在播放。

**规则**
- 高 `control-sm`（手机平板 `control-touch`），圆角 `radius-sm`，**不用胶囊形**，不加对勾。
- 未选中：`surface-hover` 底、`ink` 字；数量用 `timecode` 字体配 `ink-muted`。
- 选中：`accent-soft` 底、`accent-ink` 字。
- 选集格：`surface` 底加 `line` 描边；看过的字变 `ink-muted`；**正在播放的那一集是这个区域里唯一的 `accent` 填充**，字用 `on-accent`。
- 线路名后面跟这一条有几集（「演示直链 24」），线路坏了自动换走时这里同步。

**在 Flutter 里**：`ChoiceChip` / `FilterChip` 的主题；选集格在详情页和播放器面板里。
