import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tea_stall_pos/main.dart';

void main() {
  testWidgets('Tea Stall POS starts', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(create: (_) => PosStore(), child: const TeaStallApp()));
    expect(find.text('Tea Stall POS'), findsOneWidget);
  });
}
