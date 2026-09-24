import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// Botão circular/pílula do controle. Suporta toque, pressionamento longo
/// (início/fim) e estado desabilitado quando a tecla não existe no protocolo.
class RemoteButton extends StatefulWidget {
  const RemoteButton({
    super.key,
    this.icon,
    this.label,
    this.semanticLabel,
    required this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
    this.size = 64,
    this.accent = false,
    this.enabled = true,
    this.haptics = true,
    this.child,
  }) : assert(icon != null || label != null || child != null);

  final IconData? icon;
  final String? label;
  final String? semanticLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;
  final double size;
  final bool accent;
  final bool enabled;
  final bool haptics;
  final Widget? child;

  @override
  State<RemoteButton> createState() => _RemoteButtonState();
}

class _RemoteButtonState extends State<RemoteButton> {
  bool _pressed = false;

  void _feedback() {
    if (widget.haptics) HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).extension<RemoteButtonStyle>()!;
    final enabled = widget.enabled && widget.onTap != null;
    final fg = !enabled ? style.disabled : (widget.accent ? style.onAccent : style.icon);
    final bg = !enabled
        ? style.fill.withValues(alpha: 0.5)
        : _pressed
        ? (widget.accent ? style.accent.withValues(alpha: 0.7) : style.fillPressed)
        : (widget.accent ? style.accent : style.fill);

    final content =
        widget.child ??
        (widget.icon != null
            ? Icon(widget.icon, size: widget.size * 0.42, color: fg)
            : Text(
                widget.label!,
                style: TextStyle(color: fg, fontSize: widget.size * 0.3, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ));

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled
            ? () {
                _feedback();
                widget.onTap!();
              }
            : null,
        onLongPressStart: enabled && widget.onLongPressStart != null
            ? (_) {
                HapticFeedback.mediumImpact();
                setState(() => _pressed = true);
                widget.onLongPressStart!();
              }
            : null,
        onLongPressEnd: enabled && widget.onLongPressEnd != null
            ? (_) {
                setState(() => _pressed = false);
                widget.onLongPressEnd!();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(widget.size / 2),
            border: style.border == BorderSide.none ? null : Border.fromBorderSide(style.border),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Pílula vertical/horizontal com duas ações (ex.: volume +/-).
class RemotePill extends StatelessWidget {
  const RemotePill({
    super.key,
    required this.topIcon,
    required this.bottomIcon,
    required this.onTop,
    required this.onBottom,
    this.label,
    this.enabled = true,
    this.width = 64,
    this.height = 150,
  });

  final IconData topIcon;
  final IconData bottomIcon;
  final VoidCallback? onTop;
  final VoidCallback? onBottom;
  final String? label;
  final bool enabled;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).extension<RemoteButtonStyle>()!;
    final fg = enabled ? style.icon : style.disabled;
    Widget half(IconData icon, VoidCallback? cb, String sem) => Expanded(
      child: Semantics(
        button: true,
        label: sem,
        child: InkWell(
          onTap: enabled && cb != null
              ? () {
                  HapticFeedback.lightImpact();
                  cb();
                }
              : null,
          borderRadius: BorderRadius.circular(width / 2),
          child: Center(
            child: Icon(icon, color: fg, size: width * 0.4),
          ),
        ),
      ),
    );
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: enabled ? style.fill : style.fill.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(width / 2),
        border: style.border == BorderSide.none ? null : Border.fromBorderSide(style.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          half(topIcon, onTop, '${label ?? ''} +'),
          if (label != null)
            Text(
              label!,
              style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1),
            ),
          half(bottomIcon, onBottom, '${label ?? ''} -'),
        ],
      ),
    );
  }
}
