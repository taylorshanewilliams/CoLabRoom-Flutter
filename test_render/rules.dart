// What "good" actually means, measured rather than argued about.
//
// Every check in this file is somebody else's published number, not a taste
// call, and each one names its source. That matters because the alternative —
// two people looking at a screenshot and disagreeing — is how a layout defect
// survives three rounds of review. A ratio of 2.9:1 is not a matter of
// opinion.
//
// What this can and cannot do is worth being blunt about. These rules catch
// **defects**: unreadable text, targets a thumb misses, lines nobody can
// track, screens that leave most of themselves empty. They say nothing about
// whether the app is worth using. No measurement here would have objected to
// a beautifully accessible product nobody wanted.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

enum Severity {
  /// Fails a published accessibility threshold. Somebody cannot use this.
  fails,

  /// Inside the letter of the standard, outside the recommendation.
  warns,

  /// Worth a human's eye. Not a violation of anything.
  notes,
}

class Finding {
  Finding({
    required this.rule,
    required this.standard,
    required this.detail,
    required this.severity,
    this.screen = '',
    this.device = '',
  });

  /// What was measured.
  final String rule;

  /// Whose number, so a disagreement is with them and not with the harness.
  final String standard;

  final String detail;
  final Severity severity;
  String screen;
  String device;
}

// ------------------------------------------------------------------ contrast

/// WCAG 2.2 relative luminance. §Relative luminance, W3C.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  // WCAG is written entirely in 8-bit sRGB, so the packed form is the one
  // that matches the formula rather than the wide-gamut doubles.
  final argb = c.toARGB32();
  final r = ((argb >> 16) & 0xFF).toDouble();
  final g = ((argb >> 8) & 0xFF).toDouble();
  final b = (argb & 0xFF).toDouble();
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/// The WCAG contrast ratio between two opaque colours, 1.0 to 21.0.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final light = math.max(la, lb);
  final dark = math.min(la, lb);
  return (light + 0.05) / (dark + 0.05);
}

/// The ratio this particular text has to reach.
///
/// WCAG 2.2 SC 1.4.3 (Contrast, Minimum, AA): 4.5:1 for body text, relaxed to
/// 3:1 for "large scale" text — which the spec defines as at least 18pt, or
/// 14pt bold. In Flutter's logical pixels at the CSS reference resolution
/// that is 24px, or 18.66px at w700 and above.
double requiredContrast(double fontSize, FontWeight? weight) {
  final bold = (weight?.value ?? FontWeight.w400.value) >= FontWeight.w700.value;
  if (fontSize >= 24) return 3.0;
  if (bold && fontSize >= 18.66) return 3.0;
  return 4.5;
}

/// Reads the text on screen and measures it against what it is drawn on.
///
/// The background is **sampled from the rendered pixels**, not guessed from
/// the widget tree, and that is what makes this trustworthy. Walking up
/// looking for the nearest ancestor that paints a colour gets it wrong
/// constantly: a gradient, a translucent scrim, an image, a Material
/// elevation overlay, or simply a Container three levels further up than the
/// one you stopped at. The pixels have already resolved all of it.
///
/// Taking the *modal* colour inside the text's own bounds works because
/// glyphs cover well under half of their box — so the most common pixel in a
/// line of text is the thing behind the line of text.
List<Finding> auditContrast(
  WidgetTester tester,
  Uint8List pixels,
  int width,
  int height,
) {
  final findings = <Finding>[];

  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!paragraph.attached || paragraph.debugNeedsLayout) continue;
    final style = _firstStyle(paragraph.text);
    final color = style?.color;
    if (color == null || color.a < 0.78) continue;

    final plain = paragraph.text.toPlainText(includeSemanticsLabels: false);
    if (_isIconOrEmpty(plain)) continue;

    final size = paragraph.size;
    if (size.width < 8 || size.height < 6) continue;

    final Offset origin;
    try {
      origin = paragraph.localToGlobal(Offset.zero);
    } catch (_) {
      continue;
    }
    final rect = Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
    final behind = _modalColour(pixels, width, height, rect);
    if (behind == null) continue;

    final fontSize = style?.fontSize ?? 14.0;
    final need = requiredContrast(fontSize, style?.fontWeight);
    final got = contrastRatio(color, behind);
    if (got >= need) continue;

    final excerpt =
        plain.length > 42 ? '${plain.substring(0, 42)}…' : plain;
    findings.add(Finding(
      rule: 'Text contrast',
      standard: 'WCAG 2.2 SC 1.4.3 (AA) — ${need.toStringAsFixed(1)}:1',
      detail: '"${excerpt.replaceAll('\n', ' ')}" is '
          '${got.toStringAsFixed(2)}:1 — ${_hex(color)} on ${_hex(behind)} '
          'at ${fontSize.toStringAsFixed(0)}px',
      severity: Severity.fails,
    ));
  }
  return findings;
}

/// Whether this paragraph is an icon rather than words.
///
/// `Icon` is a Text of one character from the MaterialIcons private use area,
/// and measuring it as text produces nonsense in both directions. Its
/// background, sampled from its own bounds, is the glyph colour — so every
/// icon in the app reported as 1.00:1 against itself. And a rule about
/// reading rhythm has nothing to say about a glyph.
bool _isIconOrEmpty(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return true;
  return trimmed.runes.every((r) =>
      (r >= 0xE000 && r <= 0xF8FF) || (r >= 0xF0000 && r <= 0xFFFFD));
}

TextStyle? _firstStyle(InlineSpan span) {
  if (span.style?.color != null) return span.style;
  TextStyle? found;
  span.visitChildren((child) {
    if (child.style?.color != null) {
      found = child.style;
      return false;
    }
    return true;
  });
  return found ?? span.style;
}

// -------------------------------------------------------------- tap  targets

/// Every place a finger is expected to land, and whether it can.
///
/// Three published numbers, and they disagree, so all three are reported:
///
///   * **WCAG 2.2 SC 2.5.8 (Target Size, Minimum, AA)** — 24x24 CSS px. The
///     floor. Below this is a conformance failure.
///   * **Material Design 3, Accessibility** — 48x48dp. Google's own number
///     for a Flutter app, and what `kMinInteractiveDimension` is set to.
///   * **Apple Human Interface Guidelines** — 44x44pt.
///
/// Taken from the semantics tree rather than by hunting for GestureDetectors,
/// because semantics is what an assistive technology sees, and a control that
/// is invisible there is already broken for a different reason.
List<Finding> auditTapTargets(WidgetTester tester) {
  final findings = <Finding>[];
  final seen = <String>{};

  _walkSemantics(tester, (node, data, rect) {
    if (!data.hasAction(SemanticsAction.tap)) return;
    // Scrollables and the root take a tap action without being a target.
    if (data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollLeft)) {
      return;
    }
    final name = data.label.isNotEmpty
        ? data.label
        : (data.tooltip.isNotEmpty ? data.tooltip : '(unlabelled)');
    final short = name.length > 40 ? '${name.substring(0, 40)}…' : name;

    final w = rect.width;
    final h = rect.height;
    if (w <= 0 || h <= 0) return;
    final smallest = math.min(w, h);

    // One finding per control, at the worst threshold it misses.
    final String standard;
    final Severity severity;
    if (smallest < 24) {
      standard = 'WCAG 2.2 SC 2.5.8 (AA) — 24x24';
      severity = Severity.fails;
    } else if (smallest < 44) {
      standard = 'Material 3 — 48x48dp · Apple HIG — 44x44pt';
      severity = Severity.warns;
    } else if (smallest < 48) {
      standard = 'Material 3 — 48x48dp';
      severity = Severity.notes;
    } else {
      return;
    }

    final key = '$short|${w.round()}x${h.round()}';
    if (!seen.add(key)) return;
    findings.add(Finding(
      rule: 'Tap target',
      standard: standard,
      detail: '"${short.replaceAll('\n', ' ')}" is '
          '${w.round()}x${h.round()}',
      severity: severity,
    ));
  });
  return findings;
}

/// Controls a screen reader would announce as nothing at all.
///
/// WCAG 2.2 SC 4.1.2 (Name, Role, Value): every user-interface component
/// needs a name that can be programmatically determined. In Flutter the
/// commonest way to fail this is an `IconButton` with no tooltip and an
/// `InkWell` wrapping an `Icon` — both of which look completely finished.
List<Finding> auditLabels(WidgetTester tester) {
  final findings = <Finding>[];
  final seen = <String>{};

  _walkSemantics(tester, (node, data, rect) {
    if (!data.hasAction(SemanticsAction.tap)) return;
    if (data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollLeft)) {
      return;
    }
    if (data.label.trim().isNotEmpty) return;
    if (data.tooltip.trim().isNotEmpty) return;
    // A node whose children carry the text — a card wrapping a Text — is
    // announced through them, so it is not silent.
    var childHasLabel = false;
    node.visitChildren((child) {
      if (child.getSemanticsData().label.trim().isNotEmpty) {
        childHasLabel = true;
        return false;
      }
      return true;
    });
    if (childHasLabel) return;

    final key = '${rect.left.round()},${rect.top.round()}'
        ',${rect.width.round()}x${rect.height.round()}';
    if (!seen.add(key)) return;
    findings.add(Finding(
      rule: 'Unnamed control',
      standard: 'WCAG 2.2 SC 4.1.2 (A)',
      detail: 'a tappable ${rect.width.round()}x${rect.height.round()} at '
          '(${rect.left.round()}, ${rect.top.round()}) announces nothing',
      severity: Severity.fails,
    ));
  });
  return findings;
}

void _walkSemantics(
  WidgetTester tester,
  void Function(SemanticsNode node, SemanticsData data, Rect rect) visit,
) {
  final root = _rootSemantics(tester);
  if (root == null) return;

  void walk(SemanticsNode node, Matrix4 inherited) {
    final transform = inherited.clone();
    if (node.transform != null) transform.multiply(node.transform!);
    final rect = MatrixUtils.transformRect(transform, node.rect);
    visit(node, node.getSemanticsData(), rect);
    node.visitChildren((child) {
      walk(child, transform);
      return true;
    });
  }

  walk(root, Matrix4.identity());
}

/// The semantics tree, found by descending the pipeline owners.
///
/// `RendererBinding.pipelineOwner` is deprecated because Flutter grew more
/// than one view: semantics now live on the child owners rather than the
/// root, so this searches rather than reaching for a single well-known one.
SemanticsNode? _rootSemantics(WidgetTester tester) {
  SemanticsNode? found;
  void search(PipelineOwner owner) {
    found ??= owner.semanticsOwner?.rootSemanticsNode;
    if (found == null) owner.visitChildren(search);
  }

  search(tester.binding.rootPipelineOwner);
  return found;
}

// -------------------------------------------------------------- line measure

/// How many characters a line of running text carries.
///
/// 45–75 characters is the range in Bringhurst, *The Elements of
/// Typographic Style* (§2.1.2), and the one every legibility study since has
/// landed near: past about 75 the eye loses the return sweep and starts
/// re-reading lines; under about 45 it is interrupted so often that the
/// reading rhythm never establishes.
///
/// This is the check that would have caught the workspace at 1920 — lyrics in
/// a column of roughly fifteen characters — and the one that would object
/// just as loudly to running the same text edge to edge across a monitor.
/// Both are the same defect and neither throws an exception.
List<Finding> auditMeasure(WidgetTester tester, Size viewport) {
  final findings = <Finding>[];
  final seen = <String>{};

  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!paragraph.attached || paragraph.debugNeedsLayout) continue;
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    // Running text only. A label, a button and a heading are all short by
    // design and have nothing to do with reading rhythm.
    if (text.length < 90 || _isIconOrEmpty(text)) continue;

    final style = _firstStyle(paragraph.text);
    final fontSize = style?.fontSize ?? 14.0;
    // Roboto's average advance across mixed-case English is close to half its
    // point size; exact enough to tell 15 characters from 60 from 190, which
    // is the only distinction this rule needs to make.
    final chars = paragraph.size.width / (fontSize * 0.5);
    if (chars >= 45 && chars <= 75) continue;

    final excerpt = text.length > 38 ? '${text.substring(0, 38)}…' : text;
    final key = '$excerpt|${chars.round()}';
    if (!seen.add(key)) continue;

    findings.add(Finding(
      rule: chars < 45 ? 'Line too short' : 'Line too long',
      standard: 'Bringhurst §2.1.2 — 45–75 characters',
      detail: '~${chars.round()} characters '
          '(${paragraph.size.width.round()}px at ${fontSize.toStringAsFixed(0)}px) '
          '— "${excerpt.replaceAll('\n', ' ')}"',
      severity: chars < 30 || chars > 100 ? Severity.warns : Severity.notes,
    ));
  }
  return findings;
}

// ---------------------------------------------------------- use of the space

/// Where the content actually is, measured off the rendered pixels.
///
/// This exists because of a specific complaint that no other check in this
/// file would register: *"there's tons of wasted space, and more importantly,
/// too much stuff condensed into one space while there's so much open space
/// un-utilised."* That is not an overflow, a contrast failure or a missing
/// label. It is a distribution, and a distribution is a number.
///
/// The page's own background is taken as the modal colour of the whole frame,
/// and every pixel that differs from it by any visible amount is content.
/// Reported as the share of the width that carries any content at all, and
/// the widest run of empty columns — because one 900px void on the right is a
/// different problem from evenly generous margins totalling the same area.
List<Finding> auditInk(
  Uint8List pixels,
  int width,
  int height, {
  required String device,
}) {
  final findings = <Finding>[];

  final w = width;
  final h = height;
  final page = _modalColour(pixels, w, h, Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
  if (page == null) return findings;
  final pageArgb = page.toARGB32();

  // A column counts as occupied if any pixel in it is visibly not the page.
  // Sampled every other row, which halves the work and changes no answer.
  final occupied = List<bool>.filled(w, false);
  for (var x = 0; x < w; x += 1) {
    for (var y = 0; y < h; y += 2) {
      final i = (y * w + x) * 4;
      final dr = (pixels[i] - ((pageArgb >> 16) & 0xFF)).abs();
      final dg = (pixels[i + 1] - ((pageArgb >> 8) & 0xFF)).abs();
      final db = (pixels[i + 2] - (pageArgb & 0xFF)).abs();
      if (dr + dg + db > 24) {
        occupied[x] = true;
        break;
      }
    }
  }

  final used = occupied.where((e) => e).length;
  final share = used / w;

  var longestGap = 0;
  var gap = 0;
  for (final on in occupied) {
    if (on) {
      gap = 0;
    } else {
      gap += 1;
      longestGap = math.max(longestGap, gap);
    }
  }

  // Only meaningful on something wider than a phone: a 390px screen is
  // supposed to be full, and a wide one is not supposed to be either full or
  // a quarter used.
  if (w < 700) return findings;

  if (share < 0.55) {
    findings.add(Finding(
      rule: 'Unused width',
      standard: 'the complaint this harness was built for',
      detail: 'only ${(share * 100).round()}% of ${w}px carries anything; '
          'the widest empty run is ${longestGap}px',
      severity: longestGap > w * 0.35 ? Severity.warns : Severity.notes,
      device: device,
    ));
  } else if (longestGap > w * 0.3) {
    findings.add(Finding(
      rule: 'A hole in the layout',
      standard: 'the complaint this harness was built for',
      detail: '${longestGap}px of the ${w}px width is a continuous empty '
          'column while content crowds elsewhere',
      severity: Severity.notes,
      device: device,
    ));
  }
  return findings;
}

// ------------------------------------------------------- what actually threw

/// A screen that threw while being drawn.
///
/// This is the harness's most valuable output and the one it would never have
/// produced if a complaint aborted the walk: the existing suite stops at the
/// first exception, so a run that finds three broken screens reports one.
List<Finding> asFindings(List<FlutterErrorDetails> complaints) {
  return <Finding>[
    for (final details in complaints)
      Finding(
        rule: 'Threw while drawing',
        standard: 'an exception is never intended',
        detail: _oneLine(details),
        severity: Severity.fails,
      ),
  ];
}

String _oneLine(FlutterErrorDetails details) {
  final raw = details.exception.toString();
  final text = LineSplitter.split(raw).firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => raw,
      ).trim();
  final where = details.context?.toDescription() ?? '';
  final full = where.isEmpty ? text : '$text ($where)';
  return full.length > 220 ? '${full.substring(0, 220)}…' : full;
}

// ------------------------------------------------------------------- pixels

/// The commonest colour inside a rectangle, quantised so that anti-aliasing
/// and a subtle gradient still agree with themselves.
Color? _modalColour(Uint8List pixels, int width, int height, Rect rect) {
  final left = rect.left.floor().clamp(0, width - 1);
  final top = rect.top.floor().clamp(0, height - 1);
  final right = rect.right.ceil().clamp(1, width);
  final bottom = rect.bottom.ceil().clamp(1, height);
  if (right <= left || bottom <= top) return null;

  // Stepped, so a full-screen call stays cheap without changing the mode.
  final stepX = math.max(1, (right - left) ~/ 160);
  final stepY = math.max(1, (bottom - top) ~/ 160);

  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      final i = (y * width + x) * 4;
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final bucket = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      counts[bucket] = (counts[bucket] ?? 0) + 1;
      final sum = sums.putIfAbsent(bucket, () => <int>[0, 0, 0, 0]);
      sum[0] += r;
      sum[1] += g;
      sum[2] += b;
      sum[3] += 1;
    }
  }
  if (counts.isEmpty) return null;

  var best = counts.keys.first;
  var bestCount = -1;
  counts.forEach((bucket, count) {
    if (count > bestCount) {
      best = bucket;
      bestCount = count;
    }
  });
  // The bucket's average rather than its centre, so the reported hex is a
  // colour that is genuinely on screen.
  final sum = sums[best]!;
  final n = sum[3];
  return Color.fromARGB(255, sum[0] ~/ n, sum[1] ~/ n, sum[2] ~/ n);
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF)
    .toRadixString(16)
    .padLeft(6, '0')
    .toUpperCase()}';

// ------------------------------------------------------------------- report

/// One file somebody reads, ordered so the first thing on it is the worst
/// thing in the app.
Future<File> writeReport(List<Finding> findings, {required String path}) async {
  const order = <Severity, int>{
    Severity.fails: 0,
    Severity.warns: 1,
    Severity.notes: 2,
  };

  // One button with no label appears on nine screens across six devices, and
  // listing it fifty-four times buries everything else. The same defect is
  // one row, carrying the list of places it was seen — which is more useful
  // anyway, because "on every device" and "only on the desk" are different
  // bugs.
  final merged = <String, Finding>{};
  final places = <String, Set<String>>{};
  for (final f in findings) {
    final key = '${f.rule}|${f.detail}';
    merged.putIfAbsent(key, () => f);
    final where = <String>[
      if (f.device.isNotEmpty) f.device,
      if (f.screen.isNotEmpty) f.screen,
    ].join(' · ');
    if (where.isNotEmpty) places.putIfAbsent(key, () => <String>{}).add(where);
  }

  // Severity first, then rule — so every contrast failure sits under one
  // heading instead of splitting into two whenever the required ratio differs
  // between a heading and a caption.
  final sorted = merged.values.toList()
    ..sort((a, b) {
      final bySeverity = order[a.severity]!.compareTo(order[b.severity]!);
      return bySeverity != 0 ? bySeverity : a.rule.compareTo(b.rule);
    });

  final fails = sorted.where((f) => f.severity == Severity.fails).length;
  final warns = sorted.where((f) => f.severity == Severity.warns).length;
  final notes = sorted.where((f) => f.severity == Severity.notes).length;

  final out = StringBuffer()
    ..writeln('# What the app measures')
    ..writeln()
    ..writeln('Rendered at real sizes with real fonts, then measured against '
        'published thresholds. Every row names the standard it is citing.')
    ..writeln()
    ..writeln('| | count |')
    ..writeln('|---|---|')
    ..writeln('| Fails a published threshold | $fails |')
    ..writeln('| Inside the letter, outside the recommendation | $warns |')
    ..writeln('| Worth a look | $notes |')
    ..writeln();

  if (sorted.isEmpty) {
    out.writeln('Nothing measured outside its threshold.');
  }

  String? lastRule;
  String? lastStandard;
  for (final f in sorted) {
    final heading = '${_mark(f.severity)} — ${f.rule}';
    if (heading != lastRule) {
      out
        ..writeln()
        ..writeln('## $heading')
        ..writeln();
      lastRule = heading;
      lastStandard = null;
    }
    // Printed when it changes, so a rule with one threshold states it once
    // and a rule with several says which item is which.
    if (f.standard != lastStandard) {
      out
        ..writeln('*${f.standard}*')
        ..writeln();
      lastStandard = f.standard;
    }
    final seen = (places['${f.rule}|${f.detail}'] ?? const <String>{}).toList()
      ..sort();
    final where = seen.length <= 3
        ? seen.join(', ')
        : '${seen.take(3).join(', ')} and ${seen.length - 3} more';
    out.writeln('- ${f.detail}${where.isEmpty ? '' : '  \n  _($where)_'}');
  }

  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(out.toString(), flush: true);
  return file;
}

String _mark(Severity s) => switch (s) {
      Severity.fails => 'Fails',
      Severity.warns => 'Warns',
      Severity.notes => 'Notes',
    };
