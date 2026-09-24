import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/entities/remote_key.dart';

/// D-pad circular no estilo do controle do Chromecast: anel com quatro
/// direções e botão central de confirmação.
class DPad extends StatefulWidget {
  const DPad({super.key, required this.onKey, this.onLongStart, this.onLongEnd, this.size = 240, this.enabled = true});

  final void Function(RemoteKey key) onKey;
  final void Function(RemoteKey key)? onLongStart;
  final void Function(RemoteKey key)? onLongEnd;
  final double size;
  final bool enabled;

  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  RemoteKey? _pressed;

  RemoteKey? _hit(Offset local) {
    final c = widget.size / 2;
    final dx = local.dx - c;
    final dy = local.dy - c;
    final r = math.sqrt(dx * dx + dy * dy);
    if (r > c) return null;
    if (r < c * 0.38) return RemoteKey.ok;
    final angle = math.atan2(dy, dx); // -pi..pi, 0 = direita
    if (angle >= -math.pi / 4 && angle < math.pi / 4) return RemoteKey.right;
    if (angle >= math.pi / 4 && angle < 3 * math.pi / 4) return RemoteKey.down;
    if (angle >= -3 * math.pi / 4 && angle < -math.pi / 4) return RemoteKey.up;
    return RemoteKey.left;
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).extension<RemoteButtonStyle>()!;
    return Semantics(
      label: 'Direcional',
      child: GestureDetector(
        onTapDown: widget.enabled ? (d) => setState(() => _pressed = _hit(d.localPosition)) : null,
        onTapUp: widget.enabled
            ? (d) {
                final k = _hit(d.localPosition);
                setState(() => _pressed = null);
                if (k != null) {
                  HapticFeedback.lightImpact();
                  widget.onKey(k);
                }
              }
            : null,
        onTapCancel: () => setState(() => _pressed = null),
        onLongPressStart: widget.enabled && widget.onLongStart != null
            ? (d) {
                final k = _hit(d.localPosition);
                if (k == null) return;
                HapticFeedback.mediumImpact();
                setState(() => _pressed = k);
                widget.onLongStart!(k);
              }
            : null,
        onLongPressEnd: widget.enabled && widget.onLongEnd != null
            ? (d) {
                final k = _pressed;
                setState(() => _pressed = null);
                if (k != null) widget.onLongEnd!(k);
              }
            : null,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _DPadPainter(style: style, pressed: _pressed, enabled: widget.enabled),
        ),
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  _DPadPainter({required this.style, required this.pressed, required this.enabled});
  final RemoteButtonStyle style;
  final RemoteKey? pressed;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final ring = Paint()..color = enabled ? style.dpadRing : style.dpadRing.withValues(alpha: 0.5);
    canvas.drawCircle(c, r, ring);

    // Setor pressionado
    if (pressed != null && pressed != RemoteKey.ok) {
      final start = switch (pressed!) {
        RemoteKey.right => -math.pi / 4,
        RemoteKey.down => math.pi / 4,
        RemoteKey.left => 3 * math.pi / 4,
        _ => -3 * math.pi / 4,
      };
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..arcTo(Rect.fromCircle(center: c, radius: r), start, math.pi / 2, false)
        ..close();
      canvas.drawPath(path, Paint()..color = style.fillPressed);
    }

    if (style.border != BorderSide.none) {
      canvas.drawCircle(
        c,
        r - style.border.width / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.border.width
          ..color = style.border.color,
      );
    }

    // Centro
    final centerR = r * 0.38;
    canvas.drawCircle(c, centerR, Paint()..color = pressed == RemoteKey.ok ? style.fillPressed : style.dpadCenter);
    if (style.border != BorderSide.none) {
      canvas.drawCircle(
        c,
        centerR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.border.width
          ..color = style.border.color,
      );
    }

    // Setas
    final arrow = Paint()
      ..color = enabled ? style.icon : style.disabled
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final d = r * 0.72;
    final s = r * 0.075;
    void chevron(Offset p, double rot) {
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(rot);
      canvas.drawPath(
        Path()
          ..moveTo(-s, s * 0.6)
          ..lineTo(0, -s * 0.6)
          ..lineTo(s, s * 0.6),
        arrow,
      );
      canvas.restore();
    }

    chevron(c + Offset(0, -d), 0);
    chevron(c + Offset(d, 0), math.pi / 2);
    chevron(c + Offset(0, d), math.pi);
    chevron(c + Offset(-d, 0), -math.pi / 2);
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.pressed != pressed || old.enabled != enabled || old.style != style;
}
