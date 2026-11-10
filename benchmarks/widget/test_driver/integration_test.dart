// Host side of `mise run test:grid-pixels`: runs the integration test on the
// device and fails when it fails. The per-case lines are printed by the
// test and saved in build/integration_response_data.json.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
