library game_module;

import 'package:angular/angular.dart';

import 'game_controller.dart';

class GameModule extends Module {
  GameModule() {
    type(GameController);
  }
}

