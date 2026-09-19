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
// Material rather than widgets, for InkResponse: an icon-only button in this
// app is one, and widgets.dart has never heard of it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'eyes.dart' show isOverflow;

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
/// Getting the *background* right took three attempts and both of the obvious
/// methods were wrong, in opposite directions:
///
///   * The modal colour **inside** the text's box, on the reasoning that
///     glyphs cover well under half of it. A short bold label in a tight box
///     is mostly glyph, so the background came back as the text colour and
///     the rule confidently reported 1.00:1 against itself.
///   * The modal colour of a **ring just outside** the box, where no glyph
///     reaches. For text that fills a small button the ring clears the button
///     entirely and reports the page behind it — so every filled button in
///     the app failed, with the button's own fill nowhere in the numbers.
///
/// What works is to sample inside the box and discard the pixels that are the
/// text: whatever is left is the background, whether that is a button fill, a
/// card, a gradient or a photograph. When too little is left to be sure, the
/// ring is the fallback, and when that is also unconvincing the rule declines
/// to judge — a measurement nobody can trust is worse than no measurement,
/// because somebody acts on it.
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
    final behind = _backgroundBehind(pixels, width, height, rect, color);
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

/// The style a paragraph is actually drawn in.
///
/// Merged rather than picked. A RichText's root carries the size and the child
/// span carries the colour, so returning whichever one happened to name a
/// colour reported a caption's colour at the heading's font size — which then
/// chose the wrong WCAG threshold for it. "CoLabRoom · 0.4.0" was measured at
/// 48px.
TextStyle? _firstStyle(InlineSpan span) {
  final root = span.style;
  if (root?.color != null) return root;
  TextStyle? child;
  span.visitChildren((node) {
    if (node.style?.color != null) {
      child = node.style;
      return false;
    }
    return true;
  });
  if (child == null) return root;
  return root == null ? child : root.merge(child);
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
    // A node merged into its parent is never announced on its own: the parent
    // is the thing a screen reader lands on, and it carries this node's
    // actions along with its own words.
    //
    // Without this the rule accused every FloatingActionButton in the app of
    // saying nothing. `FloatingActionButton` ends its build with
    // `MergeSemantics`, so the tooltip sits on the parent and the tap action
    // on the child — and reading the child alone reported the Record button,
    // which announces "Record something", as a silent 56x56 square on four
    // screens of every walk. That is the worst kind of finding: confidently
    // wrong, about the most prominent control in the app, in a report whose
    // whole value is that people believe it.
    if (node.isMergedIntoParent) return;
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

// --------------------------------------------------- what a painting says

/// One painted thing a screen reader is told nothing about.
///
/// Kept as a record rather than turned straight into a [Finding], because the
/// same list is wanted twice and read two different ways. By widget type, so
/// the debt reads as "one waveform and eleven icon-only controls" rather than
/// as fifty rows nobody counts. And by screen, so somebody paying it down
/// knows which screen to open.
///
/// Every Musician, Same Song, 17 September 2026: #357 made the chord diagrams
/// speak, and this is the part that stops the next one shipping silent.
class SilentThing {
  SilentThing({
    required this.kind,
    required this.what,
    required this.size,
    this.screen = '',
    this.device = '',
  });

  /// Which of [kinds] painted it.
  final String kind;

  /// Which one — the painter's class, the image's provider, or the icon and
  /// the control it sits in. Enough to find it in the source.
  final String what;

  final Size size;
  String screen;
  String device;

  /// How the snapshot names it.
  ///
  /// The size is deliberately left out. The same silent control is a
  /// different number of pixels on every device and at every text size, so a
  /// list keyed on pixels would churn on a font change and teach people to
  /// re-record it without reading it.
  String get line => '$kind · $what';

  /// Drawn by one of the app's own [CustomPainter]s.
  static const String painting = 'CustomPaint';

  /// An `Image` with no `semanticLabel`, announced as a blank image.
  static const String image = 'Image';

  /// A control whose whole face is an icon, and which nobody named.
  static const String iconControl = 'Icon-only control';

  /// Every kind, in the order a report should read them.
  static const List<String> kinds = <String>[painting, image, iconControl];
}

/// Everything painted on this screen that announces nothing.
///
/// WCAG 2.1 SC 1.1.1 (Non-text Content, A): anything that is not text and
/// carries meaning needs a text alternative, and anything that is pure
/// decoration has to be marked so an assistive technology can skip it. A
/// `CustomPaint` is neither by default — it contributes no semantics
/// whatsoever, so a chord diagram, a tuner needle and a waveform are all, to
/// VoiceOver and TalkBack, the same blank rectangle. An `Image` is announced,
/// and announced as nothing: `RawImage` always builds a semantics node with
/// whatever label it was given, and the default is the empty string. An icon
/// with nothing else in the button is the third, and the commonest. Nothing
/// throws and nothing looks wrong, which is why this class of defect survives
/// review.
///
/// Read off the widget tree rather than the semantics tree, because the thing
/// being measured is what is *missing* from the semantics tree: a silent
/// `CustomPaint` leaves no node to find. So every painted widget is asked the
/// question a screen reader answers — land here, and is anything said? — by
/// walking up until some ancestor settles it.
///
/// **Only this app's own painters are judged.** The framework paints too —
/// Scrollbar and CircularProgressIndicator are both a `CustomPaint` — and
/// reporting those would be the harness blaming the app for Flutter's
/// choices, which is the fastest way to teach people to ignore a report.
/// Which painters belong to the app is read off `lib/` rather than kept as a
/// list here, so a painter written next week is covered on the day it is
/// written by somebody who has never heard of this file.
///
/// A painting passes by being **named** or by being **declared decoration**,
/// and it has to be one of the two: silence is the thing being measured. The
/// walk up stops at the first ancestor that settles it, which is why it is
/// not capped at some number of ancestors. A painting inside a labelled card
/// is therefore credited to the card, which is true, and is the one place
/// this rule is deliberately generous.
List<SilentThing> silentPaint(
  WidgetTester tester, {
  Set<String>? painters,
}) {
  final owned = painters ?? appPainters();
  final found = <SilentThing>[];
  final seen = <String>{};

  void add(String kind, String what, Element element) {
    final box = element.renderObject;
    final size = box is RenderBox && box.hasSize ? box.size : Size.zero;
    final key = '$kind|$what|${size.width.round()}x${size.height.round()}';
    if (!seen.add(key)) return;
    found.add(SilentThing(kind: kind, what: what, size: size));
  }

  for (final element in find.byType(CustomPaint).evaluate()) {
    final paint = element.widget as CustomPaint;
    final mine = <String>[
      for (final painter in <CustomPainter?>[paint.painter, paint.foregroundPainter])
        if (painter != null && owned.contains(painter.runtimeType.toString()))
          painter.runtimeType.toString(),
    ];
    if (mine.isEmpty) continue;
    // A painter can carry its own semantics rather than being wrapped in
    // them, which is the right answer for a drawing with several meaningful
    // parts, and counts.
    if (paint.painter?.semanticsBuilder != null ||
        paint.foregroundPainter?.semanticsBuilder != null) {
      continue;
    }
    if (_namedOrExcluded(element)) continue;
    add(SilentThing.painting, mine.join(' and '), element);
  }

  for (final element in find.byType(Image).evaluate()) {
    final picture = element.widget as Image;
    // Two ways an Image settles the question itself, and both are on the
    // widget rather than above it: a label of its own, or a declaration that
    // it is decoration and contributes nothing.
    if ((picture.semanticLabel ?? '').trim().isNotEmpty) continue;
    if (picture.excludeFromSemantics) continue;
    if (_namedOrExcluded(element)) continue;
    add(SilentThing.image, picture.image.runtimeType.toString(), element);
  }

  for (final element in find.byType(Icon).evaluate()) {
    final icon = element.widget as Icon;
    // `Icon` builds its own `Semantics` *below* itself, so the label it was
    // given is not something a walk up the tree can see.
    if ((icon.semanticLabel ?? '').trim().isNotEmpty) continue;
    if (_namedOrExcluded(element)) continue;
    // A decorative icon beside words is not a defect — it is the normal way
    // to draw a list row, and flagging every one of them would bury the
    // handful that matter. What is being looked for is the icon that *is* the
    // control: nothing above it says a word, and there is nothing else inside
    // the control to read.
    final control = _tappableAbove(element);
    if (control == null) continue;
    if (_holdsWords(control)) continue;
    add(
      SilentThing.iconControl,
      '${icon.icon} in ${control.widget.runtimeType}',
      element,
    );
  }

  return found;
}

/// Paintings a screen reader is told nothing about, as findings.
///
/// An icon-only control is left out on purpose: [auditLabels] already reports
/// it, from the semantics side, as a tappable that announces nothing, and two
/// headings for one button is how a report gets ignored. It stays in
/// [silentPaint], where naming the icon and the control it sits in is the
/// whole point.
List<Finding> auditPaintedMeaning(
  WidgetTester tester, {
  Set<String>? painters,
}) =>
    paintedMeaning(silentPaint(tester, painters: painters));

/// The same findings, from a list already gathered.
///
/// The walk gathers [silentPaint] once per screen and needs it twice — once
/// as findings for the report, once as the list itself for the worklist and
/// the snapshot — and walking the whole element tree a second time to answer
/// the same question would be the harness being slow for no reason.
List<Finding> paintedMeaning(List<SilentThing> things) {
  final findings = <Finding>[];
  for (final thing in things) {
    if (thing.kind == SilentThing.iconControl) continue;
    final drawn = '${thing.size.width.round()}x${thing.size.height.round()}';
    final subject = thing.kind == SilentThing.painting
        ? thing.what
        : 'an Image (${thing.what})';
    findings.add(Finding(
      rule: 'A painting that says nothing',
      standard: 'WCAG 2.1 SC 1.1.1 (A)',
      detail: '$subject draws $drawn with no semantics label, and is not '
          'declared decoration',
      severity: Severity.fails,
    ));
  }
  return findings;
}

/// Whether anything above [element] either names it or declares it decoration.
///
/// Read off the widget tree rather than the render tree because `Semantics`
/// and `ExcludeSemantics` carry what they were asked for in public fields,
/// while their render objects keep it private — and because this is the same
/// tree the walk in `the_app_test.dart` already matches labels in.
bool _namedOrExcluded(Element element) {
  var settled = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ExcludeSemantics) {
      if (!widget.excluding) return true;
      settled = true;
      return false;
    }
    if (widget is Semantics) {
      final properties = widget.properties;
      // Hint and value as well as label and tooltip: a control announced as
      // "82 beats per minute" is not silent, and neither is one whose only
      // words are the hint saying what pressing it does.
      final named = <String?>[
        properties.label,
        properties.tooltip,
        properties.value,
        properties.hint,
      ].any((text) => (text ?? '').trim().isNotEmpty);
      if (!named) return true;
      settled = true;
      return false;
    }
    return true;
  });
  return settled;
}

/// The control [element] is the face of, if it is the face of one.
///
/// The first tappable ancestor, which for an `IconButton` is the `InkResponse`
/// the button builds rather than the button itself — the element tree runs
/// through what was built, and naming that is honest and still enough to find
/// the thing in the source.
Element? _tappableAbove(Element element) {
  Element? control;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if ((widget is InkResponse && widget.onTap != null) ||
        (widget is GestureDetector && widget.onTap != null)) {
      control = ancestor;
      return false;
    }
    return true;
  });
  return control;
}

/// Whether anything under [root] is words rather than a glyph.
///
/// `Text` builds a `RichText`, so one check covers both — and an `Icon` builds
/// one too, holding a single character from the icon font, which is exactly
/// what must not count as words here.
bool _holdsWords(Element root) {
  var words = false;
  void walk(Element element) {
    if (words) return;
    final widget = element.widget;
    if (widget is RichText &&
        !_isIconOrEmpty(
            widget.text.toPlainText(includeSemanticsLabels: false))) {
      words = true;
      return;
    }
    element.visitChildren(walk);
  }

  root.visitChildren(walk);
  return words;
}

Set<String>? _appPainters;

/// Every `CustomPainter` this app declares, read off its own source.
///
/// Kept here rather than in a hand-written list because a hand-written list
/// is a thing that goes stale silently: the painter added in six months is
/// exactly the one nobody thinks to add to it, and a rule that quietly stops
/// covering new work is worse than no rule.
///
/// `lib/` is found relative to wherever the process was started, so this is
/// only right when the harness is run from the package root. See
/// [paintersUnder] for what happens when it is not.
Set<String> appPainters() => _appPainters ??= paintersUnder(Directory('lib'));

/// Every `CustomPainter` declared under [source].
///
/// Throws rather than returning nothing when there is no source to read, which
/// is the stale-list argument one step further on: a run from the wrong
/// directory -- a tools package, a subdirectory, a future harness that moves
/// -- would otherwise judge no painters at all and report a clean sheet
/// forever. A rule that cannot find what it judges has to fail, not pass.
Set<String> paintersUnder(Directory source) {
  final names = <String>{};
  final declaration = RegExp(r'class\s+(\w+)\s+extends\s+CustomPainter\b');
  if (source.existsSync()) {
    for (final entity in source.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final match in declaration.allMatches(entity.readAsStringSync())) {
        names.add(match.group(1)!);
      }
    }
  }
  if (names.isEmpty) {
    throw StateError(
      'No CustomPainter declared under ${source.absolute.path}. Run this from '
      'the package root, where lib/ is: the painted-meaning rule judges the '
      'app by its own source, and cannot report on source it cannot read.',
    );
  }
  return names;
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

// ------------------------------------------------- how much a screen asks

/// How many separate things a person could tap here.
///
/// The best single proxy for "is this screen asking too much of somebody".
/// Not a threshold — a dense list of songs is *supposed* to have forty
/// tappable rows, and a screen with one button is not therefore better. What
/// it is good for is comparison: two screens doing a similar job with very
/// different counts is worth a look, and a screen whose count climbed without
/// anybody adding a feature is worth a look too.
///
/// Counted off the semantics tree, so it is what an assistive technology
/// would enumerate — which is also a fair model of what somebody scanning a
/// screen has to work through.
int countControls(WidgetTester tester) {
  final seen = <String>{};
  _walkSemantics(tester, (node, data, rect) {
    if (!data.hasAction(SemanticsAction.tap)) return;
    if (data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollLeft)) {
      return;
    }
    if (rect.width <= 0 || rect.height <= 0) return;
    // Position, so two buttons with the same label are two buttons and one
    // button drawn twice is one.
    seen.add('${rect.left.round()},${rect.top.round()},'
        '${rect.width.round()}x${rect.height.round()}');
  });
  return seen.length;
}

/// How many words a person is actually presented with.
///
/// Counted off the **semantics tree**, and the first two attempts at this got
/// it wrong in ways worth recording.
///
/// Walking `allRenderObjects` counts every built paragraph, which on a pushed
/// route means the screen underneath as well: `MaterialPageRoute` keeps the
/// route below in the tree, so the Inbox was being credited with the whole of
/// the Songs tab sitting behind it. That is why compressing three sentences on
/// the Inbox moved the number by six words while visibly changing the screen —
/// most of what was being counted was not the Inbox at all.
///
/// Clipping to the viewport rectangle does not fix it, because the route below
/// occupies exactly the same rectangle. What does fix it is asking the same
/// tree an assistive technology asks: semantics stops at the top route, which
/// is also the honest definition of what somebody is being presented with.
int countWords(WidgetTester tester, Size viewport) {
  var words = 0;
  final counted = <String>{};
  _walkSemantics(tester, (node, data, rect) {
    if (!rect.overlaps(Offset.zero & viewport)) return;
    final text = <String>[data.label, data.value]
        .where((part) => part.trim().isNotEmpty)
        .join(' ');
    if (text.trim().isEmpty) return;
    // A node and its merged parent can carry the same string; counting a
    // heading twice because a card repeated it is not the screen's fault.
    final key = '${rect.left.round()},${rect.top.round()}|$text';
    if (!counted.add(key)) return;
    words += text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  });
  return words;
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
      // An overflow reads as its own row rather than as one more exception.
      // It is the one complaint here that is a gate: the walk fails on it, so
      // somebody reading the report should not have to pick it out of a
      // heading that also holds font fetches and absent platform channels.
      if (isOverflow(details))
        Finding(
          rule: 'Overflowed',
          standard: 'text wraps or the screen scrolls; nothing is cut off '
              '(WCAG 2.1 AA §1.4.4 Resize text)',
          detail: '${_oneLine(details)}${_whichWidget(details)}',
          severity: Severity.fails,
        )
      else
        Finding(
          rule: 'Threw while drawing',
          standard: 'an exception is never intended',
          detail: _oneLine(details),
          severity: Severity.fails,
        ),
  ];
}

/// The file and line of the widget that could not fit, when Flutter knows it.
///
/// "A RenderFlex overflowed by 26 pixels on the bottom" costs an investigation
/// to locate, and a finding that costs an investigation is a finding people
/// stop chasing — which is the exact complaint test/every_screen_draws_test
/// already makes about this. Flutter names the widget in the full report, in
/// the form `Column:file:///…/out_there.dart:127:20`, so the gate quotes it
/// and somebody can open the line.
String _whichWidget(FlutterErrorDetails details) {
  final match =
      RegExp(r'file:///\S*?/lib/(\S+?\.dart:\d+:\d+)').firstMatch('$details');
  return match == null ? '' : ' — lib/${match.group(1)}';
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

/// The background behind some text: inside its box, minus the glyph.
///
/// [text] is the colour the glyph is painted in, and every pixel close to it
/// is thrown away — including the anti-aliased edges, which sit between the
/// two colours and would otherwise pull the answer toward the middle.
Color? _backgroundBehind(
  Uint8List pixels,
  int width,
  int height,
  Rect rect,
  Color text,
) {
  final left = rect.left.floor().clamp(0, width - 1);
  final top = rect.top.floor().clamp(0, height - 1);
  final right = rect.right.ceil().clamp(1, width);
  final bottom = rect.bottom.ceil().clamp(1, height);
  if (right <= left || bottom <= top) return _backgroundAround(pixels, width, height, rect);

  final argb = text.toARGB32();
  final tr = (argb >> 16) & 0xFF;
  final tg = (argb >> 8) & 0xFF;
  final tb = argb & 0xFF;

  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  var kept = 0;
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      final i = (y * width + x) * 4;
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      // Anything near the ink is ink. 90 across three channels is wide enough
      // to take the anti-aliased skirt with it and narrow enough to keep a
      // background that merely happens to be dark.
      if ((r - tr).abs() + (g - tg).abs() + (b - tb).abs() < 90) continue;
      final bucket = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      counts[bucket] = (counts[bucket] ?? 0) + 1;
      final sum = sums.putIfAbsent(bucket, () => <int>[0, 0, 0, 0]);
      sum[0] += r;
      sum[1] += g;
      sum[2] += b;
      sum[3] += 1;
      kept += 1;
    }
  }

  // The glyph is not there.
  //
  // Every pixel in this box is far from the colour the style names, which
  // means the text is not actually painted in that colour — it is behind
  // something. A modal sheet dims what is under it, and a route transition
  // fades the screen it is leaving; in both cases the widget tree still
  // reports a full-strength colour that nobody is being shown. Measuring
  // that produced a run's worth of confident failures against the Open Mic's
  // own tab bar, sitting quietly under a scrim, doing nothing wrong.
  final total = (right - left) * (bottom - top);
  final ink = total - kept;
  if (total > 0 && ink / total < 0.03) return null;

  // Barely any background visible, or no colour among it that dominates:
  // this text is over something busy, and a single number does not describe
  // it. Try the ring, and if that is no better say nothing.
  if (kept < 30) return _backgroundAround(pixels, width, height, rect);
  final modal = _pickModal(counts, sums);
  if (modal == null) return _backgroundAround(pixels, width, height, rect);
  final dominance = _modalShare(counts) ;
  if (dominance < 0.5) return null;
  return modal;
}

double _modalShare(Map<int, int> counts) {
  var total = 0;
  var best = 0;
  counts.forEach((_, count) {
    total += count;
    if (count > best) best = count;
  });
  return total == 0 ? 0 : best / total;
}

/// What is painted immediately around [rect].
///
/// A thin ring rather than a wide one, so text sitting near the edge of a
/// button or a card samples that button rather than whatever the card is
/// sitting on. Where the ring falls off the image — text hard against the
/// screen edge — it simply has fewer pixels to work with, and when it has too
/// few to be meaningful the rule declines to judge rather than guessing.
Color? _backgroundAround(Uint8List pixels, int width, int height, Rect rect) {
  const gap = 2.0;
  const thickness = 5.0;
  final inner = rect.inflate(gap);
  final outer = rect.inflate(gap + thickness);

  final left = outer.left.floor().clamp(0, width - 1);
  final top = outer.top.floor().clamp(0, height - 1);
  final right = outer.right.ceil().clamp(1, width);
  final bottom = outer.bottom.ceil().clamp(1, height);
  if (right <= left || bottom <= top) return null;

  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  var samples = 0;
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      if (inner.contains(Offset(x.toDouble(), y.toDouble()))) continue;
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
      samples += 1;
    }
  }
  // Too little to be sure is a reason to say nothing. A rule that guesses
  // here produces exactly the confident nonsense this one replaced.
  if (samples < 40) return null;

  return _pickModal(counts, sums);
}

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
  return _pickModal(counts, sums);
}

Color? _pickModal(Map<int, int> counts, Map<int, List<int>> sums) {
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

// ------------------------------------------------ what says nothing, listed

/// The silent-paint list as a snapshot: one sorted line per screen and thing.
///
/// This is the form that gets committed and compared, so everything in it has
/// to be the same on every machine and at every text size. Screen and widget
/// type and which thing it is; no pixels, no positions, no device — those
/// belong in the report a person reads, not in a file a test compares.
List<String> silentPaintLines(Iterable<SilentThing> things) {
  final lines = <String>{
    for (final thing in things)
      '${thing.screen.isEmpty ? '(no screen)' : thing.screen} · ${thing.line}',
  }.toList()
    ..sort();
  return lines;
}

/// The debt, by widget type and by screen.
///
/// A separate file from `REPORT.md` because it is read for a different reason.
/// The report is "what is wrong with the app today"; this is a worklist, and
/// the useful shape of a worklist is the one that says how many of each kind
/// there are and where to open the app to find them.
Future<File> writeSilentPaint(
  List<SilentThing> things, {
  required String path,
}) async {
  // One row per distinct thing, carrying the screens it was seen on. The same
  // unlabelled avatar on six screens across nine devices is one job, not
  // fifty-four rows.
  final rows = <String, SilentThing>{};
  final places = <String, Set<String>>{};
  for (final thing in things) {
    final key = '${thing.kind}|${thing.what}';
    rows.putIfAbsent(key, () => thing);
    if (thing.screen.isNotEmpty) {
      places.putIfAbsent(key, () => <String>{}).add(thing.screen);
    }
  }

  final out = StringBuffer()
    ..writeln('# What says nothing')
    ..writeln()
    ..writeln('Painted things a screen reader is told nothing about: no '
        'label, no hint, no value, and no declaration that they are '
        'decoration. WCAG 2.1 SC 1.1.1 (A) and SC 4.1.2 (A).')
    ..writeln()
    ..writeln('This is a worklist, not a gate. The gate is '
        '`test/nothing_new_says_nothing_test.dart`, which holds the same '
        'list and fails when something is added to it.')
    ..writeln();

  if (rows.isEmpty) {
    out.writeln('Nothing painted on this walk is silent.');
  }

  for (final kind in SilentThing.kinds) {
    final mine = rows.entries.where((e) => e.value.kind == kind).toList()
      ..sort((a, b) => a.value.what.compareTo(b.value.what));
    if (mine.isEmpty) continue;
    out
      ..writeln()
      ..writeln('## $kind — ${mine.length}')
      ..writeln();
    for (final entry in mine) {
      final where = (places[entry.key] ?? const <String>{}).toList()..sort();
      final screens = where.length <= 4
          ? where.join(', ')
          : '${where.take(4).join(', ')} and ${where.length - 4} more';
      out.writeln('- ${entry.value.what}, '
          '${entry.value.size.width.round()}x'
          '${entry.value.size.height.round()}'
          '${screens.isEmpty ? '' : '  \n  _($screens)_'}');
    }
  }

  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(out.toString(), flush: true);
  return file;
}
