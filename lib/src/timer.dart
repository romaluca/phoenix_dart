import 'dart:async';

class PhoenixTimer {
  Function callback;
  Function timerCalc;
  Timer timer;
  int tries;

  PhoenixTimer(this.callback, this.timerCalc){
    timer     = null;
    tries     = 0;
  }

  void reset(){
    tries = 0;
    if(timer != null) {
      timer.cancel();
    }
  }

  void scheduleTimeout(){
    if (timer != null)
      timer.cancel();
    timer = new Timer(new Duration(milliseconds: timerCalc(tries + 1)), () {
      tries = tries + 1;
      callback();
    });
  }
}
