// Kept so `flutter create .` doesn't generate its default counter-app test.
import 'package:flutter_test/flutter_test.dart';
import 'package:tcg_price_tagger/main.dart';
import 'package:tcg_price_tagger/settings.dart';

void main() {
  testWidgets('shows the open-photo screen', (tester) async {
    await tester.pumpWidget(TcgPriceTaggerApp(settings: AppSettings()));
    expect(find.text('Open a photo of the cards you are selling'), findsOneWidget);
  });
}
