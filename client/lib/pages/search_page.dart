import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import '../ui/device_form.dart';
import '../ui/phone_input.dart';
import '../ui/poster.dart';
import '../ui/tv/tv_focus.dart';
import '../ui/tv/tv_keyboard.dart';
import '../ui/tv/tv_text_input.dart';
import 'browse_page.dart' show errorText;
import 'detail_page.dart';

/// Aggregated search: results stream in as each site answers.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.focusNode});

  /// Lets the shell put the cursor in the search box (Ctrl+F).
  final FocusNode? focusNode;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _field = TextEditingController();
  StreamSubscription<SearchEvent>? _sub;
  final _results = <VodCard>[];
  final _perSite = <String, int>{};
  final _started = <String>{};
  final _finished = <String>{};
  final _failed = <String, String>{};
  String? _query;
  String? _siteFilter;
  String? _error;
  bool _searching = false;

  @override
  void dispose() {
    _sub?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _search() {
    final q = _field.text.trim();
    if (q.isEmpty) return;
    if (DeviceFormScope.readIsTv(context)) _rememberQuery(q);
    _sub?.cancel();
    setState(() {
      _query = q;
      _results.clear();
      _perSite.clear();
      _started.clear();
      _finished.clear();
      _failed.clear();
      _siteFilter = null;
      _error = null;
      _searching = true;
    });
    _sub = AppScope.read(context).client
        .searchAll(q)
        .listen(
          (event) {
            setState(() {
              switch (event) {
                case SearchSiteStatus(:final site, :final status, :final message):
                  _started.add(site);
                  if (status == 'done') _finished.add(site);
                  if (status == 'error') {
                    _finished.add(site);
                    _failed[site] = message ?? '失败';
                  }
                case SearchResults(:final site, :final items):
                  _results.addAll(items);
                  _perSite[site] = (_perSite[site] ?? 0) + items.length;
                case SearchEnd():
                  _searching = false;
              }
            });
          },
          onError: (Object e) => setState(() {
            _error = errorText(e);
            _searching = false;
          }),
          onDone: () => setState(() => _searching = false),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final visible = _siteFilter == null ? _results : _results.where((v) => v.site == _siteFilter).toList();
    if (isTv(context)) return _buildTv(context, state, visible);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: TextField(
                controller: _field,
                focusNode: widget.focusNode,
                enabled: state.hasConfig,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: state.hasConfig ? '搜索片名，所有站点同时搜' : (state.loadingConfig ? '正在加载订阅…' : '先在"源"里导入订阅'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? IconButton(
                          onPressed: () => _sub?.cancel().then((_) => setState(() => _searching = false)),
                          icon: const Icon(Icons.stop_circle_outlined),
                        )
                      : null,
                ),
              ),
            ),
            if (_query != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    if (_searching) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    if (_searching) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_searching ? '搜索中' : '搜索完成'} · ${_finished.length}/${_started.length} 个站点 · 找到 ${_results.length} 条'
                        '${_failed.isEmpty ? '' : ' · ${_failed.length} 个站点失败'}',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            if (_perSite.length > 1)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('全部 ${_results.length}'),
                        selected: _siteFilter == null,
                        onSelected: (_) => setState(() => _siteFilter = null),
                      ),
                    ),
                    for (final e in _perSite.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('${state.siteName(e.key)} ${e.value}'),
                          selected: _siteFilter == e.key,
                          onSelected: (_) => setState(() => _siteFilter = e.key),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(child: _body(visible, state)),
          ],
        ),
      ),
    );
  }

  Widget _body(List<VodCard> visible, AppState state) {
    if (_error != null) return StatusView(icon: Icons.cloud_off, message: '搜索失败\n$_error', actionLabel: '重试', onAction: _search);
    if (_query == null) return const StatusView(icon: Icons.travel_explore, message: '输入片名后回车');
    if (visible.isEmpty) {
      return _searching ? const LoadingView() : StatusView(icon: Icons.search_off, message: '没有找到"$_query"');
    }
    return GridView.builder(
      // Scrolling the results puts the on-screen keyboard away.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      gridDelegate: posterGridDelegate,
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final vod = visible[i];
        return PosterCard(vod: vod, caption: state.siteName(vod.site), onTap: () => openDetail(context, vod));
      },
    );
  }

  // ---- TV: an on-screen keyboard on the left, the results on the right; recent searches before the first one.

  static const _recentKey = 'search.recent';

  List<String> _recentQueries() =>
      (AppScope.read(context).settings.getString(_recentKey) ?? '').split('\n').where((s) => s.trim().isNotEmpty).toList();

  void _rememberQuery(String q) {
    final list = [q, ..._recentQueries().where((s) => s != q)].take(12).toList();
    AppScope.read(context).settings.setString(_recentKey, list.join('\n'));
  }

  Widget _buildTv(BuildContext context, AppState state, List<VodCard> visible) {
    final scheme = Theme.of(context).colorScheme;
    final recent = _query == null && _error == null ? _recentQueries() : const <String>[];
    return Scaffold(
      // The system keyboard covers the letter keys instead of squeezing them; the field is at the top.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 296,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('tv-search-field'),
                      controller: _field,
                      focusNode: widget.focusNode,
                      enabled: state.hasConfig,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      style: const TextStyle(fontSize: 20),
                      decoration: InputDecoration(
                        hintText: state.hasConfig ? '片名、拼音或首字母' : (state.loadingConfig ? '正在加载订阅…' : '先在"源"里导入订阅'),
                        prefixIcon: const Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TvSearchKeyboard(
                        controller: _field,
                        onSearch: _search,
                        onSystemInput: widget.focusNode == null ? null : () => TvTextInputGate.openKeyboard(widget.focusNode!),
                        onPhoneInput: () async {
                          final text = await showPhoneInput(
                            context,
                            const PhoneInputRequest(title: '搜索词', hint: '片名', keyboard: PhoneKeyboard.search),
                          );
                          if (text == null || text.isEmpty || !mounted) return;
                          _field.text = text;
                          _search();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_query != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: Text(
                        '「$_query」${_searching ? '搜索中' : '搜索完成'} · ${_finished.length}/${_started.length} 个站点 · 找到 ${_results.length} 条'
                        '${_failed.isEmpty ? '' : ' · ${_failed.length} 个站点失败'}',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                      ),
                    ),
                  if (_perSite.length > 1)
                    SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(label: Text('全部 ${_results.length}'), selected: _siteFilter == null, onSelected: (_) => setState(() => _siteFilter = null)),
                          ),
                          for (final e in _perSite.entries)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text('${state.siteName(e.key)} ${e.value}'),
                                selected: _siteFilter == e.key,
                                onSelected: (_) => setState(() => _siteFilter = e.key),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: recent.isNotEmpty
                        ? _recentOnTv(recent)
                        : _query == null && _error == null
                        ? const StatusView(icon: Icons.travel_explore, message: '用左边的键盘输入片名、拼音或首字母，再按「搜索」\n中文和语音用「中文 / 语音」，也可以用「手机输入」在手机上打字')
                        : _body(visible, state),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recentOnTv(List<String> recent) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        Text('最近搜索', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final q in recent)
              TvFocusable(
                onTap: () {
                  _field.text = q;
                  _search();
                },
                scale: 1.08,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(999)),
                  child: Text(q, style: const TextStyle(fontSize: 17)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
