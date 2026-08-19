import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/name_policy.dart';
import 'cheat_sheet_screen.dart';
import 'toolbox_models.dart';
import 'toolbox_order_store.dart';
import 'toolbox_tile.dart';

class ToolboxCategoryScreen extends StatefulWidget {
  const ToolboxCategoryScreen({required this.category, super.key});

  final ToolboxCategory category;

  @override
  State<ToolboxCategoryScreen> createState() => _ToolboxCategoryScreenState();
}

class _ToolboxCategoryScreenState extends State<ToolboxCategoryScreen> {
  String _query = '';
  List<String> _order = const <String>[];
  bool _loadingOrder = true;

  String get _orderKey => 'toolbox_order_sheets_${widget.category.id}';

  @override
  void initState() {
    super.initState();
    ToolboxOrderStore.load(_orderKey).then((order) {
      if (mounted) setState(() {
        _order = order;
        _loadingOrder = false;
      });
    });
  }

  void _reorder(List<CheatSheet> visibleSheets, String draggedId, int dropIndex) {
    if (draggedId == visibleSheets[dropIndex].id) return;
    final ids = visibleSheets.map((s) => s.id).toList();
    final draggedIndex = ids.indexOf(draggedId);
    if (draggedIndex == -1) return;
    final id = ids.removeAt(draggedIndex);
    ids.insert(dropIndex, id);
    setState(() => _order = ids);
    unawaited(ToolboxOrderStore.save(_orderKey, ids));
  }

  @override
  Widget build(BuildContext context) {
    final category = widget.category;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(category.name),
      ),
      body: _loadingOrder
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context, category),
    );
  }

  Widget _buildBody(BuildContext context, ToolboxCategory category) {
    if (!category.hasContent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(category.icon, size: 44, color: AppColors.orange),
              const SizedBox(height: 12),
              const Text('More sheets for this instrument are coming soon.'),
            ],
          ),
        ),
      );
    }

    final query = NamePolicy.normalized(_query);
    final ordered = applyToolboxOrder(category.sheets, _order, (s) => s.id);
    final visible = query.isEmpty
        ? ordered
        : ordered.where((s) => NamePolicy.normalized(s.title).contains(query)).toList(growable: false);

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          sliver: SliverToBoxAdapter(
            child: Text(category.tagline, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ),
        ),
        if (category.sheets.length > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            sliver: SliverToBoxAdapter(
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search cheat sheets',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
          ),
        if (visible.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No sheets match “$_query”.')),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final count = width >= 1100 ? 4 : width >= 700 ? 3 : 2;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 10,
                    mainAxisExtent: 172,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final sheet = visible[index];
                      void onTap() {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CheatSheetScreen(category: category, sheet: sheet),
                          ),
                        );
                      }

                      if (query.isNotEmpty) {
                        return ToolboxTile(
                          key: ValueKey<String>(sheet.id),
                          title: sheet.title,
                          subtitle: 'Cheat sheet',
                          icon: sheet.icon,
                          onTap: onTap,
                        );
                      }
                      return _DraggableSheetTile(
                        key: ValueKey<String>(sheet.id),
                        sheet: sheet,
                        onTap: onTap,
                        onReorder: (draggedId) => _reorder(visible, draggedId, index),
                      );
                    },
                    childCount: visible.length,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _DraggableSheetTile extends StatefulWidget {
  const _DraggableSheetTile({
    required this.sheet,
    required this.onTap,
    required this.onReorder,
    super.key,
  });

  final CheatSheet sheet;
  final VoidCallback onTap;
  final ValueChanged<String> onReorder;

  @override
  State<_DraggableSheetTile> createState() => _DraggableSheetTileState();
}

class _DraggableSheetTileState extends State<_DraggableSheetTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.sheet.id,
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onReorder(details.data);
      },
      onMove: (_) => setState(() => _hovering = true),
      onLeave: (_) => setState(() => _hovering = false),
      builder: (context, candidates, rejected) {
        return LongPressDraggable<String>(
          data: widget.sheet.id,
          delay: const Duration(milliseconds: 220),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: 164,
              height: 172,
              child: Transform.scale(
                scale: 1.05,
                child: Opacity(
                  opacity: 0.9,
                  child: ToolboxTile(
                    title: widget.sheet.title,
                    subtitle: 'Cheat sheet',
                    icon: widget.sheet.icon,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.28,
            child: ToolboxTile(
              title: widget.sheet.title,
              subtitle: 'Cheat sheet',
              icon: widget.sheet.icon,
              onTap: () {},
            ),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: _hovering
                  ? Border.all(color: AppColors.orange, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
            ),
            child: ToolboxTile(
              title: widget.sheet.title,
              subtitle: 'Cheat sheet',
              icon: widget.sheet.icon,
              onTap: widget.onTap,
            ),
          ),
        );
      },
    );
  }
}
