import 'dart:async';

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';

/// Agrega várias fontes de descoberta em um único stream.
class CompositeDiscovery implements DeviceDiscovery {
  CompositeDiscovery(this.sources);
  final List<DeviceDiscovery> sources;

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    var open = sources.length;
    final subs = <StreamSubscription<DiscoveredDevice>>[];
    ctrl.onListen = () {
      for (final s in sources) {
        subs.add(
          s
              .discover(timeout: timeout)
              .listen(
                (d) {
                  if (!ctrl.isClosed) ctrl.add(d);
                },
                onError: (_) {},
                onDone: () {
                  if (--open == 0 && !ctrl.isClosed) ctrl.close();
                },
              ),
        );
      }
    };
    ctrl.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return ctrl.stream;
  }
}
