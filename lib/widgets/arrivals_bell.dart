import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/arrivals_screen.dart';
import '../services/brain_new_arrivals_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../utils/navigation_helper.dart';

/// Колокольчик в шапку: бейдж непрочитанных + своя страница.
/// Виден всегда, не зависит от системных разрешений.
class ArrivalsBell extends StatelessWidget {
  final Color? iconColor;
  const ArrivalsBell({super.key, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Consumer2<BrainNewArrivalsService, KumaFlowBrainBridge>(
      builder: (context, arrivals, bridge, _) {
        final n = arrivals.unread;
        return Stack(
          alignment: Alignment.topRight,
          children: [
            IconButton(
              icon: Icon(
                n > 0
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                color: n > 0
                    ? const Color(0xFFFFC107)
                    : iconColor,
              ),
              tooltip: n > 0
                  ? 'Новинки ($n)'
                  : 'Новинки от подписок',
              onPressed: () {
                NavigationHelper.push(
                    context, const ArrivalsScreen());
              },
            ),
            if (n > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    n > 99 ? '99+' : '$n',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            if (bridge.isActive &&
                arrivals.lastError != null &&
                n == 0)
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
