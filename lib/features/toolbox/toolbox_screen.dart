import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/name_policy.dart';
import 'toolbox_category_screen.dart';
import 'toolbox_content.dart';
import 'toolbox_models.dart';
import 'toolbox_order_store.dart';
import 'toolbox_tile.dart';

const _orderKey = 'toolbox_order_categories';

class ToolboxScreen extends StatefulWidget {
  const ToolboxScreen({super.key});

  @override
  State<ToolboxScreen> createState() => _ToolboxScreenState();
}

class _ToolboxScreenState extends State<ToolboxScreen> {
  String _query = '';
  List<String> _order = const <String>[];
  bool _loadingOrder = true;

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

  void _reorder(String draggedId, int dropIndex) {
    final ordered = applyToolboxOrder(toolboxCategories, _order, (c) => c.id);
    if (draggedId == ordered[dropIndex].id) return;
    final ids = ordered.map((c) => c.id).toList();
    final draggedIndex = ids.indexOf(draggedId);
    if (draggedIndex == -1) return;
    final id = ids.removeAt(draggedIndex);
    ids.insert(dropIndex, id);
    setState(() => _order = ids);
    unawaited(ToolboxOrderStore.save(_orderKey, ids));
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingOrder) {
      return const Center(child: CircularProgressIndicator());
    }
    final query = NamePolicy.normalized(_query);
    final ordered = applyToolboxOrder(toolboxCategories, _order, (c) => c.id);
    final visible = query.isEmpty
        ? ordered
        : ordered.where((c) => NamePolicy.normalized(c.name).contains(query)).toList(growable: false);

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Toolbox', style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 4),
                const Text(
                  'Reference sheets for every instrument — drag to reorder, yours to arrange.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          sliver: SliverToBoxAdapter(
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search the Toolbox',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
        ),
        if (visible.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No categories match “$_query”.')),
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
                      final category = visible[index];
                      void onTap() {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ToolboxCategoryScreen(category: category),
                          ),
                        );
                      }

                      if (query.isNotEmpty) {
                        return ToolboxTile(
                          key: ValueKey<String>(category.id),
                          title: category.name,
                          subtitle: category.tagline,
                          icon: category.icon,
                          onTap: onTap,
                        );
                      }
                      return _DraggableToolboxCategoryTile(
                        key: ValueKey<String>(category.id),
                        category: category,
                        onTap: onTap,
                        onReorder: (draggedId) => _reorder(draggedId, index),
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

class _DraggableToolboxCategoryTile extends StatefulWidget {
  const _DraggableToolboxCategoryTile({
    required this.category,
    required this.onTap,
    required this.onReorder,
    super.key,
  });

  final ToolboxCategory category;
  final VoidCallback onTap;
  final ValueChanged<String> onReorder;

  @override
  State<_DraggableToolboxCategoryTile> createState() => _DraggableToolboxCategoryTileState();
}

class _DraggableToolboxCategoryTileState extends State<_DraggableToolboxCategoryTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.category.id,
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onReorder(details.data);
      },
      onMove: (_) => setState(() => _hovering = true),
      onLeave: (_) => setState(() => _hovering = false),
      builder: (context, candidates, rejected) {
        return LongPressDraggable<String>(
          data: widget.category.id,
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
                    title: widget.category.name,
                    subtitle: widget.category.tagline,
                    icon: widget.category.icon,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.28,
            child: ToolboxTile(
              title: widget.category.name,
              subtitle: widget.category.tagline,
              icon: widget.category.icon,
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
              title: widget.category.name,
              subtitle: widget.category.tagline,
              icon: widget.category.icon,
              onTap: widget.onTap,
            ),
          ),
        );
      },
    );
  }
}
