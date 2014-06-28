import 'dart:html';

import 'package:angular/angular.dart';
import 'package:angular/application_factory.dart';

import 'game_module.dart';

void main() {
  Application app = applicationFactory();
  app.addModule(new GameModule());
  app.run();
}

