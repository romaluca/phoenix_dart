import 'dart:async';

class PhoenixTimer {
  var callback;
  var timerCalc;
  Timer timer;
  var tries;

  PhoenixTimer(callback, timerCalc){
    this.callback  = callback;
    this.timerCalc = timerCalc;
    this.timer     = null;
    this.tries     = 0;
  }

  void reset(){
    this.tries = 0;
    if(this.timer != null) {
      this.timer.cancel();
    }
  }

  void scheduleTimeout(){
    if (this.timer != null)
      this.timer.cancel();
    this.timer = new Timer(new Duration(milliseconds: this.timerCalc(this.tries + 1)), () {
      this.tries = this.tries + 1;
      this.callback();
    });    
  }
}
