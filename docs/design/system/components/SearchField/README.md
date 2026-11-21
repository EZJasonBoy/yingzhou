# SearchField

搜索框：所有站点一起搜，边搜边出结果。

**用在**：搜索页顶部；电视上换成大号的输入条，打字交给手机输入或屏幕键盘。

**使用方提供**：当前文字、占位提示、提交时做什么、清空时做什么。

**规则**
- 高 `control-md`（手机平板 `control-touch`），圆角 `radius-sm`，`surface-hover` 底，没有描边。
- 占位提示写能搜什么：「片名、拼音或首字母」，用 `ink-faint`。
- 输入中：底变 `surface`，描边变 `focus`，光标 `accent-ink`；右侧出现清空按钮。
- 回车就搜，不另放「搜索」按钮。

**在 Flutter 里**：搜索页的 `TextField`，样式来自 `inputDecorationTheme`。
