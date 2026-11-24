import 'dart:async';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../core/emoji_catalog.dart';
import '../services/emoji_recents.dart';
import 'emoji_glyph.dart';

/// The same offline catalog serves message reactions and the text composer.
class ReactionPicker extends StatefulWidget {
  const ReactionPicker({
    super.key,
    this.selectedEmoji,
    this.inserting = false,
    this.recents,
  });
  final String? selectedEmoji;
  final bool inserting;
  final EmojiRecents? recents;
  @override
  State<ReactionPicker> createState() => _ReactionPickerState();
}

class _ReactionPickerState extends State<ReactionPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final _recents = widget.recents ?? EmojiRecents.instance;
  String? _category;
  String _query = '';
  List<EmojiEntry> _visible = EmojiCatalog.entries;
  static const _categoryIcons = [
    Icons.sentiment_satisfied_alt,
    Icons.back_hand_outlined,
    Icons.pets_outlined,
    Icons.restaurant_outlined,
    Icons.flight_outlined,
    Icons.sports_soccer_outlined,
    Icons.lightbulb_outline,
    Icons.tag,
    Icons.flag_outlined,
  ];
  @override
  void initState() {
    super.initState();
    unawaited(
      _recents.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter({String? query, String? category, bool allCategories = false}) {
    setState(() {
      if (query != null) _query = query.trim().toLowerCase();
      if (allCategories) _category = null;
      if (category != null) _category = category;
      _visible = EmojiCatalog.entries
          .where((entry) {
            if (_category != null && entry.category != _category) return false;
            if (_query.isEmpty) return true;
            return '${entry.emoji} ${entry.name} ${entry.englishName} ${entry.category} ${entry.keywords}'
                .toLowerCase()
                .contains(_query);
          })
          .toList(growable: false);
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _select(String emoji) {
    unawaited(_recents.remember(emoji));
    Navigator.pop(context, emoji);
  }

  Widget _emojiButton(String emoji, {bool recent = false}) {
    final entry = EmojiCatalog.find(emoji);
    // Never reveal which reaction belongs to this device, including through AX.
    final action = widget.inserting
        ? context.tr('插入', 'Insert')
        : context.tr('回应', 'React');
    return Semantics(
      label: context.tr(
        '${entry?.name ?? emoji}，$action',
        '${entry?.englishName ?? emoji}, $action',
      ),
      button: true,
      onTap: () => _select(emoji),
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey(
              '${recent ? 'reaction-recent' : 'reaction-grid'}-$emoji',
            ),
            borderRadius: BorderRadius.circular(14),
            onTap: () => _select(emoji),
            child: Center(child: EmojiGlyph(emoji: emoji, size: 29)),
          ),
        ),
      ),
    );
  }

  String _categoryLabel(String? category) => switch (category) {
    null => context.tr('全部', 'All'),
    '表情与情感' => context.tr('表情与情感', 'Smileys & emotion'),
    '人物与手势' => context.tr('人物与手势', 'People & gestures'),
    '动物与自然' => context.tr('动物与自然', 'Animals & nature'),
    '食物与饮品' => context.tr('食物与饮品', 'Food & drink'),
    '旅行与地点' => context.tr('旅行与地点', 'Travel & places'),
    '活动与运动' => context.tr('活动与运动', 'Activities & sports'),
    '物品' => context.tr('物品', 'Objects'),
    '符号' => context.tr('符号', 'Symbols'),
    '旗帜' => context.tr('旗帜', 'Flags'),
    _ => category,
  };

  Widget _categoryButton(String? category, IconData icon) {
    final selected = _category == category;
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: ValueKey('reaction-category-${category ?? 'all'}'),
      tooltip: _categoryLabel(category),
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? colors.primaryContainer
            : Colors.transparent,
        foregroundColor: selected
            ? colors.onPrimaryContainer
            : colors.onSurfaceVariant,
      ),
      onPressed: () =>
          _filter(category: category, allCategories: category == null),
      icon: Icon(icon, size: 23),
    );
  }

  static const _grid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 58,
    mainAxisExtent: 50,
    crossAxisSpacing: 2,
    mainAxisSpacing: 2,
  );
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = math.max(
      120.0,
      media.size.height - media.viewInsets.bottom - media.padding.top - 48,
    );
    final recent = _query.isEmpty && _category == null
        ? _recents.values
        : const <String>[];
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        key: const ValueKey('reaction-picker'),
        height: math.min(560.0, available),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('reaction-search'),
                      controller: _search,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (value) => _filter(query: value),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: context.tr('搜索', 'Search'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.tr('清空搜索', 'Clear search'),
                                onPressed: () {
                                  _search.clear();
                                  _filter(query: '');
                                },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('关闭表情列表', 'Close emoji picker'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: Row(
                children: [
                  _categoryButton(null, Icons.grid_view_rounded),
                  for (
                    var index = 0;
                    index < EmojiCatalog.categories.length;
                    index++
                  )
                    _categoryButton(
                      EmojiCatalog.categories[index],
                      _categoryIcons[index],
                    ),
                ],
              ),
            ),
            Expanded(
              child: CustomScrollView(
                key: const ValueKey('reaction-catalog-scroll'),
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  if (recent.isNotEmpty) ...[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      sliver: SliverGrid.builder(
                        key: const ValueKey('reaction-recent-grid'),
                        itemCount: recent.length,
                        gridDelegate: _grid,
                        itemBuilder: (_, index) =>
                            _emojiButton(recent[index], recent: true),
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Divider(height: 16),
                      ),
                    ),
                  ],
                  if (_visible.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Icon(
                          Icons.search_off,
                          key: ValueKey('reaction-empty'),
                          semanticLabel: context.tr('没有找到表情', 'No emoji found'),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                      sliver: SliverGrid.builder(
                        key: const ValueKey('reaction-full-grid'),
                        itemCount: _visible.length,
                        gridDelegate: _grid,
                        itemBuilder: (_, index) =>
                            _emojiButton(_visible[index].emoji),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
