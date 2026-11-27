import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Компактное уведомление-пилюля: по умолчанию свёрнуто в кружок с иконкой.
///
/// При появлении может briefly развернуться с текстом и действием, затем
/// анимационно свернуться обратно в кружок. Тап по кружку либо разворачивает
/// уведомление, либо (если задан [onTap]) сразу открывает нужную страницу.
class CompactStatusNotice extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;
  final bool autoCollapseOnce;

  const CompactStatusNotice({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    this.actionLabel,
    this.onAction,
    this.onTap,
    this.onDismiss,
    this.autoCollapseOnce = false,
  });

  @override
  State<CompactStatusNotice> createState() => _CompactStatusNoticeState();
}

class _CompactStatusNoticeState extends State<CompactStatusNotice> {
  bool _expanded = false;
  Timer? _collapseTimer;

  @override
  void initState() {
    super.initState();
    if (widget.autoCollapseOnce) {
      _expanded = true;
      _collapseTimer = Timer(const Duration(milliseconds: 2200), () {
        if (!mounted) return;
        setState(() => _expanded = false);
      });
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: _handleTap,
            child: Container(
              height: 40,
              width: _expanded ? double.infinity : 40,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _expanded ? _buildExpanded() : _buildCollapsed(),
            ),
          ),
          if (widget.onDismiss != null)
            Positioned(
              right: -2,
              top: -2,
              child: GestureDetector(
                onTap: widget.onDismiss,
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCollapsed() {
    return Center(
      child: Icon(widget.icon, color: Colors.white, size: 20),
    );
  }

  Widget _buildExpanded() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(widget.icon, color: Colors.white, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.actionLabel != null && widget.onAction != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              onPressed: widget.onAction,
              child: Text(
                widget.actionLabel!,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          if (widget.onDismiss != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              onPressed: widget.onDismiss,
              child: const Icon(Icons.close_rounded,
                  color: Colors.white70, size: 18),
            ),
        ],
      ),
    );
  }
}
