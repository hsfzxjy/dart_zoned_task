import 'package:dart_zoned_task/dart_zoned_task.dart';

void main() async {
  final task = ZonedTask.fromFuture(() async {
    print(1);
    await Task.sleep(Duration(seconds: 1)).call();
    print(2);
  });
  await Future.delayed(Duration(milliseconds: 500));
  task.cancel();
  await Future.delayed(Duration(seconds: 1));
}
