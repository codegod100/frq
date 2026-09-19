/// What the boundary costs, measured rather than assumed.
///
/// The spike's architecture rebuilds the whole screen in Nim and ships it as
/// JSON on every event. That is the obvious objection to it, so this is the
/// number that answers the objection — or doesn't.
///
///   just nim-bench
import 'dart:convert';
import 'package:frq_core/frq_core.dart' as core;

void main() {
  core.resetUi();
  final json = jsonEncode({'id': 'noop'});
  print('tree size: ${core.render().toString().length} chars (as objects)');

  // The raw JSON, to say what actually crosses the wire.
  final bytes = utf8.encode(jsonEncode(_flatten(core.render())));
  print('tree bytes: ${bytes.length}');

  for (final n in [1000, 10000]) {
    var sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      core.render();
    }
    sw.stop();
    final perRender = sw.elapsedMicroseconds / n;
    print('render():   ${perRender.toStringAsFixed(1)}µs  '
        '(${(1000000 / perRender).round()}/s, '
        '${(perRender / 16666 * 100).toStringAsFixed(3)}% of a 60fps frame)');

    sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      core.dispatch('tls.toggle');
    }
    sw.stop();
    final perDispatch = sw.elapsedMicroseconds / n;
    print('dispatch(): ${perDispatch.toStringAsFixed(1)}µs  '
        '(${(1000000 / perDispatch).round()}/s)');
  }
  // ignore: unused_local_variable
  final _ = json;
}

Map<String, dynamic> _flatten(core.UiNode n) => {
      'tag': n.tag,
      'props': n.props,
      'children': n.children.map(_flatten).toList(),
    };
