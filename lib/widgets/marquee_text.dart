import 'package:flutter/material.dart';

/// Auto-scrolling текст с ping-pong анимацией при переполнении.
/// Если текст вмещается — скролл не запускается.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final double speed; // пикселей в секунду
  final Duration pauseDuration; // пауза на концах
  final Axis scrollDirection;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.speed = 30.0,
    this.pauseDuration = const Duration(milliseconds: 500),
    this.scrollDirection = Axis.horizontal,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animController;
  bool _needsScroll = false;
  double _maxScroll = 0;
  double _currentOffset = 0;
  Animation<double>? _currentTween;
  VoidCallback? _tickListener;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animController = AnimationController(vsync: this)
      ..addStatusListener(_onAnimStatus);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOverflow();
    });
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _needsScroll = false;
      _currentOffset = 0;
      _animController.stop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkOverflow();
      });
    }
  }

  void _checkOverflow() {
    if (!mounted) return;
    try {
      if (!_scrollController.hasClients) return;
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent > 0) {
        _maxScroll = maxExtent;
        _needsScroll = true;
        _startScrolling();
      } else {
        _needsScroll = false;
      }
    } catch (_) {
      _needsScroll = false;
    }
  }

  void _startScrolling() {
    if (!_needsScroll || !mounted) return;

    // Пауза перед стартом
    Future.delayed(widget.pauseDuration, () {
      if (!mounted || !_needsScroll) return;
      _animateTo(_maxScroll);
    });
  }

  void _animateTo(double target) {
    if (!mounted) return;

    final distance = (target - _currentOffset).abs();
    if (distance < 1.0) {
      _currentOffset = target;
      _onAnimStatus(AnimationStatus.completed);
      return;
    }

    final duration = Duration(
      milliseconds: (distance / widget.speed * 1000).toInt(),
    );

    _animController.duration = duration;
    _animController.forward(from: 0);

    // Один живой listener вместо накопления новых на каждый _animateTo()
    if (_tickListener != null) {
      _animController.removeListener(_tickListener!);
    }
    _currentTween = Tween<double>(
      begin: _currentOffset,
      end: target,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.linear,
    ));
    _tickListener = () {
      if (!mounted) return;
      final value = _currentTween?.value ?? _currentOffset;
      if (!_scrollController.hasClients) return;
      try {
        _scrollController.jumpTo(value);
        _currentOffset = value;
      } catch (_) {}
    };
    _animController.addListener(_tickListener!);
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // Пауза на конце, затем ping-pong обратно
      Future.delayed(widget.pauseDuration, () {
        if (!mounted || !_needsScroll) return;
        if (_currentOffset >= _maxScroll) {
          _animateTo(0);
        } else {
          _animateTo(_maxScroll);
        }
      });
    }
  }

  @override
  void dispose() {
    _animController.removeStatusListener(_onAnimStatus);
    if (_tickListener != null) {
      _animController.removeListener(_tickListener!);
    }
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: widget.scrollDirection,
          physics: const NeverScrollableScrollPhysics(),
          child: _buildContent(constraints),
        );
      },
    );
  }

  Widget _buildContent(BoxConstraints constraints) {
    if (widget.scrollDirection == Axis.vertical) {
      return IntrinsicWidth(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
          ),
          child: Text(
            widget.text,
            style: widget.style,
            softWrap: false,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: constraints.maxWidth,
      ),
      child: IntrinsicWidth(
        child: Text(
          widget.text,
          style: widget.style,
          softWrap: false,
        ),
      ),
    );
  }
}
