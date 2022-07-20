import 'dart:async';

enum _TaskState {
  notStarted,
  running,
  cancelling,
  completed,
}

class _OwnsTaskState {
  _TaskState _state = _TaskState.notStarted;

  void _toState(_TaskState newState) {
    var oldState = _state;
    _state = newState;
    if (newState != oldState) {
      _stateChanged(newState, oldState);
    }
  }

  void _stateChanged(_TaskState newState, _TaskState oldState) {}
}

class CanceledError extends Error {}

abstract class Cancelable {
  Future<void> cancel();
}

abstract class Task extends _OwnsTaskState implements Cancelable {
  static FutureTask<void> sleep(Duration duration) {
    return Task.future<void, Completer<void>>(
      (ctx) => Future.any([Future.delayed(duration), ctx.value!.future]),
      onCancel: (ctx) async => ctx.value!.completeError(CanceledError()),
      context: Completer(),
    );
  }

  static FutureTask<Never> cancelToken() {
    return Task.future<Never, Completer<Never>>(
      (ctx) => ctx.value!.future,
      onCancel: (ctx) async => ctx.value!.completeError(CanceledError()),
      context: Completer(),
    );
  }

  static Future<T> cancelable<T>(Future<T> fut) =>
      Future.any([fut, cancelToken().call()]);

  @override
  Future<void> cancel() async {
    if (_state != _TaskState.running) return;
    _toState(_TaskState.cancelling);
    return _onCanceled().whenComplete(() {
      _toState(_TaskState.completed);
    });
  }

  Future<void> _onCanceled();

  void _checkCanceled() {
    if (_state != _TaskState.running) {
      throw CanceledError();
    }
  }

  static FutureTask<T> future<T, C>(OnCallCallback<C?, Future<T>> onCall,
      {Future<void> Function(TaskContext<C?> ctx)? onCancel, C? context}) {
    return _FutureTaskBuilder(context, onCall, onCancel);
  }

  static StreamTask<T> stream<T, C>(OnCallCallback<C?, Stream<T>> onCall,
      {Future<void> Function(TaskContext<C?> ctx)? onCancel, C? context}) {
    return _StreamTaskBuilder(context, onCall, onCancel);
  }
}

abstract class FutureTask<T> extends Task {
  Future<T> call() async {
    var parent = ZonedTask.current;
    if ((parent?._state ?? _TaskState.running) != _TaskState.running) {
      _toState(_TaskState.completed);
      throw CanceledError();
    }
    parent?._add(this);
    _toState(_TaskState.running);
    try {
      return await _call();
    } finally {
      parent?._remove(this);
      if (_state == _TaskState.running) _toState(_TaskState.completed);
    }
  }

  Future<T> _call();
}

class TaskContext<C> {
  final C value;
  final void Function() checkCanceled;
  TaskContext._(this.value, this.checkCanceled);
}

typedef OnCallCallback<C, R> = R Function(TaskContext<C> ctx);

class _FutureTaskBuilder<T, C> extends FutureTask<T> {
  late final TaskContext<C> _context;
  final OnCallCallback<C, Future<T>> _onCall;
  final Future<void> Function(TaskContext<C>)? _onCancel;
  _FutureTaskBuilder(C ctxValue, this._onCall, this._onCancel) {
    _context = TaskContext._(ctxValue, _checkCanceled);
  }

  @override
  Future<T> _call() => _onCall(_context);

  @override
  Future<void> _onCanceled() async {
    if (_onCancel != null) {
      await _onCancel!(_context);
    }
  }
}

abstract class StreamTask<T> extends Task {
  Stream<T> call() async* {
    var parent = ZonedTask.current;
    if ((parent?._state ?? _TaskState.running) != _TaskState.running) {
      _toState(_TaskState.completed);
      throw CanceledError();
    }
    _toState(_TaskState.running);
    parent?._add(this);
    try {
      yield* _call();
    } finally {
      parent?._remove(this);
      if (_state == _TaskState.running) _toState(_TaskState.completed);
    }
  }

  Stream<T> _call();
}

class _StreamTaskBuilder<T, C> extends StreamTask<T> {
  late final TaskContext<C> _context;
  final OnCallCallback<C, Stream<T>> _onCall;
  final Future<void> Function(TaskContext<C>)? _onCancel;
  _StreamTaskBuilder(C ctxValue, this._onCall, this._onCancel) {
    _context = TaskContext._(ctxValue, _checkCanceled);
  }

  @override
  Stream<T> _call() => _onCall(_context);

  @override
  Future<void> _onCanceled() async {
    if (_onCancel != null) {
      await _onCancel!(_context);
    }
  }
}

typedef OnCancelCallback<T> = T? Function();

abstract class ZonedTask<T> extends _OwnsTaskState implements Cancelable {
  static const String _zoneValueKey = "__zone_task__";
  static ZonedTask? get current => Zone.current[_zoneValueKey] as ZonedTask?;

  final Set<Cancelable> _cancellables = {};

  Future<T> get future;
  Stream<T> get stream;

  final OnCancelCallback? _onCancelCallback;
  Future<void> _cancelFuture = Future.value(null);

  ZonedTask._(this._onCancelCallback);

  static ZonedTask<T> fromFuture<T>(Future<T> Function() task,
          {OnCancelCallback? onCancel}) =>
      _FutureZonedTask<T>(task, onCancel: onCancel);

  static ZonedTask<T> fromStream<T>(Stream<T> Function() task,
          {OnCancelCallback? onCancel}) =>
      _StreamZonedTask<T>(task, onCancel: onCancel);

  void _add(Cancelable c) {
    assert(_state == _TaskState.running);
    _cancellables.add(c);
  }

  void _remove(Cancelable c) {
    _cancellables.remove(c);
  }

  Future<void> _beforeCancel();
  void _afterCancel(T? result, Object error, StackTrace? trace);

  @override
  Future<void> cancel() {
    if (_state != _TaskState.running) return _cancelFuture;
    _toState(_TaskState.cancelling);

    _cancelFuture = Future.wait(_cancellables.map((c) => c.cancel()))
        .whenComplete(() => _beforeCancel())
        .whenComplete(() {
      T? cancelResult;
      Object? cancelError = CanceledError();
      StackTrace? cancelTrace;
      if (_onCancelCallback != null) {
        try {
          cancelResult = _onCancelCallback!();
        } catch (e, s) {
          cancelError = e;
          cancelTrace = s;
        }
      }
      _afterCancel(cancelResult, cancelError, cancelTrace);
      _toState(_TaskState.completed);
    });
    return _cancelFuture;
  }
}

class _StreamZonedTask<T> extends ZonedTask<T> {
  late final StreamController<T> _controller;
  StreamSubscription<T>? _sub;

  @override
  Future<T> get future {
    throw UnimplementedError();
  }

  @override
  Stream<T> get stream => _controller.stream;

  _StreamZonedTask(Stream<T> Function() task, {OnCancelCallback? onCancel})
      : super._(onCancel) {
    _controller = StreamController(onCancel: cancel);
    var parent = ZonedTask.current;
    runZoned(
      () {
        if (_state != _TaskState.notStarted ||
            (parent?._state ?? _TaskState.running) != _TaskState.running) {
          cancel();
          return;
        }

        _toState(_TaskState.running);
        parent?._add(this);
        _sub = task().listen(
          (event) {
            _controller.sink.add(event);
          },
          onError: (e, s) {
            parent?._remove(this);
            if (e is CanceledError || _state != _TaskState.running) return;
            _controller.addError(e, s);
            _controller.close();
            _toState(_TaskState.completed);
          },
          onDone: () {
            parent?._remove(this);
            if (_state != _TaskState.running) return;
            _controller.close();
            _toState(_TaskState.completed);
          },
        );
      },
      zoneValues: {ZonedTask._zoneValueKey: this},
    );
  }

  @override
  _beforeCancel() async {
    await _sub?.cancel();
  }

  @override
  void _afterCancel(T? result, Object error, StackTrace? trace) {
    if (result != null) {
      _controller.add(result);
    } else {
      _controller.addError(error, trace);
    }
    _controller.close();
  }
}

class _FutureZonedTask<T> extends ZonedTask<T> {
  late final Completer<void> _innerCompleter;
  late final Completer<T> _completer;

  @override
  Future<T> get future => _completer.future;

  @override
  Stream<T> get stream {
    throw UnimplementedError();
  }

  _FutureZonedTask(Future<T> Function() task, {OnCancelCallback? onCancel})
      : _completer = Completer(),
        _innerCompleter = Completer(),
        super._(onCancel) {
    var parent = ZonedTask.current;
    _completer.future.whenComplete(() {
      parent?._remove(this);
    });
    runZoned(
      () {
        if (_state != _TaskState.notStarted ||
            (parent?._state ?? _TaskState.running) != _TaskState.running) {
          _innerCompleter.complete();
          cancel();
          return;
        }
        _toState(_TaskState.running);
        parent?._add(this);

        task().then((result) {
          parent?._remove(this);
          _innerCompleter.complete();
          if (_state == _TaskState.running) {
            _completer.complete(result);
            _toState(_TaskState.completed);
          }
        }, onError: (e, s) {
          parent?._remove(this);
          _innerCompleter.complete();
          if (e is CanceledError || _state == _TaskState.cancelling) return;
          _completer.completeError(e, s);
          _toState(_TaskState.completed);
        });
      },
      zoneValues: {ZonedTask._zoneValueKey: this},
    );
  }

  @override
  Future<void> _beforeCancel() => _innerCompleter.future;

  @override
  void _afterCancel(T? result, Object error, StackTrace? trace) {
    if (result != null) {
      _completer.complete(result);
    } else {
      _completer.completeError(error, trace);
    }
  }
}
