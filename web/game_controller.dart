library game_controller;

import 'dart:html';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as Math;
import 'dart:typed_data';
import 'dart:web_gl' as GL;

import 'package:angular/angular.dart';
import 'package:vector_math/vector_math.dart';
import 'package:box2d/box2d.dart';
import 'package:browser_detect/browser_detect.dart';

const String VERTEX_SHADER = '''
  attribute vec3 aPosition;
  attribute vec3 aNormal;

  uniform mat4 uPMatrix;
  uniform mat4 uMVMatrix;
  uniform mat4 uRotationMatrix;

  varying vec3 normal;

  void main(void) {
    normal = (uRotationMatrix * vec4(aNormal, 1.0)).xyz;
    gl_Position = uPMatrix * uMVMatrix * vec4(aPosition, 1.0);
  }
''';

const String FRAGMENT_SHADER = '''
  precision mediump float;
  uniform vec4 uColor;
  uniform vec3 uDirectionalLight;
  varying vec3 normal;

  void main(void) {
    float diffuse = max(dot(uDirectionalLight, normal), 0.0) * 0.75 + 0.25;
    gl_FragColor = vec4(uColor.rgb * diffuse, uColor.a);
  }
''';

class Mesh {
  Vector4 color = new Vector4(1.0, 1.0, 1.0, 1.0);
  Vector3 position = new Vector3.zero();
  GL.Buffer buffer = null;
}

class RigidMesh extends Mesh {
  Body body = null;

  Vector3 _position = new Vector3.zero();
  set position (Vector3 position) {
    _position = position;
  }

  Vector3 get position {
    if(this.body == null) {
      return null;
    }

    Vector2 v2 = this.body.position;
    _position.x = v2.x;
    _position.y = v2.y;
    return _position;
  }
}

class StageComponent {
  String roll = null;
  String group = null;
  Vector4 color = new Vector4(1.0, 1.0, 1.0, 1.0);
  String name = null;
  int x = null;
  int y = null;
}

class Stage {
  int width = 20;
  int height = 15;

  Vector4 color = new Vector4(0.0, 1.0, 0.0, 1.0);

  List<StageComponent> components = new List<StageComponent>();
}


@Controller( selector: '[ctrl]', publishAs: 'ctrl' )
class GameController {
  Stage _stage;
  GL.RenderingContext _gl;

  final Vector2 gravity = new Vector2.zero();
  Vector3 light = new Vector3(0.0, 0.0, 1.0);

  int _aPosition;
  Float32List _spherePositions;
  GL.Buffer _spherePositionBuffer;
  Float32List _boxPositions;
  GL.Buffer _boxPositionBuffer;

  int _aNormal;
  Float32List _sphereNormals;
  GL.Buffer _sphereNormalBuffer;
  Float32List _boxNormals;
  GL.Buffer _boxNormalBuffer;

  GL.UniformLocation _uMVMatrix;
  GL.UniformLocation _uRotationMatrix;
  GL.UniformLocation _uPMatrix;
  GL.UniformLocation _uColor;
  GL.UniformLocation _uDirectionalLight;

  GL.Program _program;
  GL.Shader _vs;
  GL.Shader _fs;

  bool _canUseDeviceMotion = false;
  bool skipFrame = false;
  bool mouseMode = true;
  final Vector2 _mouse = new Vector2.zero();
  final Vector2 mouse = new Vector2.zero();
  final Vector3 deviceMotion = new Vector3.zero();

  World _world;

  final Matrix4 _projection = new Matrix4.identity();
  final Matrix4 _view = new Matrix4.identity();

  List<RigidMesh> _rigidSphereList = new List<RigidMesh>();
  List<RigidMesh> _rigidBoxList = new List<RigidMesh>();
  List<Mesh> _staticBoxList = new List<Mesh>();

  Scope _scope;
  Element _element;
  CanvasElement _canvas;

  int _frame = 0;

  World _createWorld() {
    _world = new World(this.gravity, true, new DefaultWorldPool());
    return _world;
  }

  FixtureDef _sphereFixtureDef;
  BodyDef _sphereBodyDef;

  void _defineSphereBody() {
    // Create shape
    CircleShape sphereShape = new CircleShape()
      ..radius = 1.0;

    // Define fixture (links body and shape)
    _sphereFixtureDef = new FixtureDef()
      ..restitution = 0.5
      ..density = 0.05
      ..shape = sphereShape;

    // Define body
    _sphereBodyDef = new BodyDef()
      ..type = BodyType.DYNAMIC
      ..position = new Vector2(0.0, 0.0);

  }

  Body _createSphereBody() {
    // Create body and fixture from definitions
    return _world.createBody(_sphereBodyDef)..createFixture(_sphereFixtureDef);
  }

  BodyDef _boxBodyDef;
  PolygonShape _boxShape;
  _defineBoxBody() {
    _boxShape = new PolygonShape()
      ..setAsBox(1.0, 1.0);

    // Define body
    _boxBodyDef = new BodyDef()
      ..position = new Vector2(0.0, 0.0);
  }

  Body _createBoxBody() {
    // Create body and fixture from definitions
    return _world.createBody(_boxBodyDef)..createFixtureFromShape(_boxShape);
  }

  void _resetCamera() {
    setViewMatrix(
      _view,
      new Vector3(0.0, 0.0, 35.0),
      new Vector3(0.0, 0.0, 0.0),
      new Vector3(0.0, 1.0, 0.0)
    );
    setPerspectiveMatrix(_projection, 60.0 * Math.PI / 180.0, _canvas.width / _canvas.height, 0.1, 100.0);
  }

  void _resetWindow() {
    _canvas.width = window.innerWidth;
    _canvas.height = window.innerHeight;
  }

  void _compileShader() {
    _vs = _gl.createShader(GL.VERTEX_SHADER);
    _gl.shaderSource(_vs, VERTEX_SHADER);
    _gl.compileShader(_vs);
    if(!_gl.getShaderParameter(_vs, GL.COMPILE_STATUS)) {
      throw(new Exception('vertex shader error: ${_gl.getShaderInfoLog(_vs)}'));
    }

    _fs = _gl.createShader(GL.FRAGMENT_SHADER);
    _gl.shaderSource(_fs, FRAGMENT_SHADER);
    _gl.compileShader(_fs);
    if(!_gl.getShaderParameter(_fs, GL.COMPILE_STATUS)) {
      throw(new Exception('fragment shader error: ${_gl.getShaderInfoLog(_fs)}'));
    }

    _program = _gl.createProgram();
    _gl.attachShader(_program, _vs);
    _gl.attachShader(_program, _fs);
    _gl.linkProgram(_program);
    if(!_gl.getProgramParameter(_program, GL.LINK_STATUS)) {
      throw(new Exception('program link error: ${_gl.getProgramInfoLog(_program)}'));
    }

    _aPosition = _gl.getAttribLocation(_program, 'aPosition');
    if(_aPosition != -1) {
      _gl.enableVertexAttribArray(_aPosition);
    }

    _aNormal = _gl.getAttribLocation(_program, 'aNormal');
    if(_aNormal != -1) {
      _gl.enableVertexAttribArray(_aNormal);
    }

    _uMVMatrix = _gl.getUniformLocation(_program, 'uMVMatrix');
    _uRotationMatrix = _gl.getUniformLocation(_program, 'uRotationMatrix');
    _uPMatrix = _gl.getUniformLocation(_program, 'uPMatrix');
    _uColor = _gl.getUniformLocation(_program, 'uColor');
    _uDirectionalLight = _gl.getUniformLocation(_program, 'uDirectionalLight');
  }

  _initWebGL() {
    _canvas = this._element.querySelector('#main-canvas');
    _gl = _canvas.getContext3d();
  }

  _initUI() {
    _canvas.onMouseMove.listen((event){
      this.mouse.setValues(
        2.0 * (event.offset.x / _canvas.width) - 1.0,
        -2.0 * (event.offset.y / _canvas.height) + 1.0
      );

      if(this.mouseMode) {
        _mouse.setFrom(this.mouse);
      }
    });

    window.onDeviceMotion.listen((DeviceMotionEvent event){
      DeviceAcceleration acl = event.accelerationIncludingGravity;
      if(acl != null && acl.x != null && acl.y != null && acl.z != null) {
        this.deviceMotion.setValues(acl.x, acl.y, acl.z);
        if(!this._canUseDeviceMotion) {
          this.mouseMode = false;
          this._canUseDeviceMotion = true;
        }
        if(!this.mouseMode) {
          if(browser.isIe) {
            _mouse.setValues(this.deviceMotion.x * 0.1, this.deviceMotion.y * 0.1);
          } else {
            _mouse.setValues(-this.deviceMotion.x * 0.1, -this.deviceMotion.y * 0.1);
          }
        }

      }
    });

    _canvas.onContextMenu.listen((event){
      event.preventDefault();
    });

    _canvas.onMouseDown.listen((event){
      event.preventDefault();
    });

    window.onResize.listen((event){
      _resetWindow();
      _resetCamera();
    });
  }

  _createSphereBuffer() {
    _spherePositionBuffer = _gl.createBuffer();
    _gl.bindBuffer(GL.ARRAY_BUFFER, _spherePositionBuffer);
    _gl.bufferDataTyped(GL.ARRAY_BUFFER, _spherePositions, GL.STATIC_DRAW);

    _sphereNormalBuffer = _gl.createBuffer();
    _gl.bindBuffer(GL.ARRAY_BUFFER, _sphereNormalBuffer);
    _gl.bufferDataTyped(GL.ARRAY_BUFFER, _sphereNormals, GL.STATIC_DRAW);
  }

  _createBoxBuffer() {
    _boxPositionBuffer = _gl.createBuffer();
    _gl.bindBuffer(GL.ARRAY_BUFFER, _boxPositionBuffer);
    _gl.bufferDataTyped(GL.ARRAY_BUFFER, _boxPositions, GL.STATIC_DRAW);

    _boxNormalBuffer = _gl.createBuffer();
    _gl.bindBuffer(GL.ARRAY_BUFFER, _boxNormalBuffer);
    _gl.bufferDataTyped(GL.ARRAY_BUFFER, _boxNormals, GL.STATIC_DRAW);
  }

  Future _loadSphere() {
    Completer completer = new Completer();
    Future future = completer.future;

    HttpRequest req = new HttpRequest();
    req.open('GET', 'assets/sphere.json');

    req.onLoad.listen((event){
      Map response = JSON.decode(req.responseText);

      _spherePositions = new Float32List.fromList(response['positions'] as List<double>);
      _sphereNormals = new Float32List.fromList(response['normals'] as List<double>);
      completer.complete(req);
    });

    req.send();

    return future;
  }

  Future _loadBox() {
    Completer completer = new Completer();
    Future future = completer.future;

    HttpRequest req = new HttpRequest();
    req.open('GET', 'assets/box.json');

    req.onLoad.listen((event){
      Map response = JSON.decode(req.responseText);

      _boxPositions = new Float32List.fromList(response['positions'] as List<double>);
      _boxNormals = new Float32List.fromList(response['normals'] as List<double>);
      completer.complete(req);
    });

    req.send();

    return future;
  }

  void restart() {
    startStage(_stage);
  }

  RigidMesh _createRigidBox(StageComponent component, Vector2 offset) {
    return new RigidMesh()
      ..color = component.color
      ..body = (
      _createBoxBody()
        ..setTransform(new Vector2(component.x * 2.0 + offset.x, component.y * 2.0 + offset.y), 0.0)
    );
  }

  RigidMesh _createRigidSphere(StageComponent component, Vector2 offset) {
    return new RigidMesh()
      ..color = component.color
      ..body = (
      _createSphereBody()
        ..setTransform(new Vector2(component.x * 2.0 + offset.x, component.y * 2.0 + offset.y), 0.0)
        ..sleepingAllowed = false
    );
  }

  void _createFrame(Stage stage) {
    int width = stage.width + 2;
    int height = stage.height + 2;
    Vector2 offset = new Vector2(-width + 1.0, -height + 1.0);

    for(int x = 0; x < width; x++) {
      _rigidBoxList.add(
        new RigidMesh()
          ..color = stage.color
          ..body = (_createBoxBody()..setTransform(new Vector2(2.0 * x + offset.x, offset.y), 0.0))
      );
      _rigidBoxList.add(
        new RigidMesh()
          ..color = stage.color
          ..body = (_createBoxBody()..setTransform(new Vector2(2.0 * x + offset.x, 2.0 * (height - 1) + offset.y), 0.0))
      );
    }

    for(int y = 1; y < height - 1; y++) {
      _rigidBoxList.add(
        new RigidMesh()
          ..color = stage.color
          ..body = (_createBoxBody()..setTransform(new Vector2(offset.x, 2.0 * y + offset.y), 0.0))
      );
      _rigidBoxList.add(
        new RigidMesh()
          ..color = stage.color
          ..body = (_createBoxBody()..setTransform(new Vector2((width - 1) * 2.0 + offset.x, 2.0 * y + offset.y), 0.0))
      );
    }
  }

  void startStage(Stage stage) {
    Vector2 offset = new Vector2(-stage.width + 1.0, -stage.height + 1.0);

    _destroyStage();
    _createFrame(stage);

    //add spheres
    stage.components.forEach((StageComponent component){
      switch(component.roll) {
        case 'ball':
          RigidMesh ball = _createRigidSphere(component, offset);
          _rigidSphereList.add(ball);
          break;
        case 'block':
          RigidMesh block = _createRigidBox(component, offset);
          _rigidBoxList.add(block);
          break;
      }
    });

    _frame = 0;
    _stage = stage;
  }

  _destroyStage (){
    _rigidSphereList.forEach((RigidMesh rigidMesh){
      _world.destroyBody(rigidMesh.body);
    });

    _rigidBoxList.forEach((RigidMesh rigidMesh){
      _world.destroyBody(rigidMesh.body);
    });

    _rigidBoxList.clear();
    _rigidSphereList.clear();
    _staticBoxList.clear();
  }

  GameController(this._scope, this._element) {
    _initWebGL();
    _compileShader();

    Future.wait([ _loadSphere(), _loadBox() ])
    .whenComplete((){
      _createSphereBuffer();
      _createBoxBuffer();

      _defineSphereBody();
      _defineBoxBody();

      _resetWindow();
      _resetCamera();
      _createWorld();

      _initUI();

      Stage stage = new Stage();
      stage.width = 20;
      stage.height = 15;
      stage.color = new Vector4(0.5, 1.0, 0.5, 1.0);

      stage.components.add(
        new StageComponent()
        ..roll = 'ball'
        ..name = null
        ..color = new Vector4(1.0, 0.0, 0.0, 1.0)
        ..x = 5
        ..y = 7
      );

      stage.components.add(
        new StageComponent()
          ..roll = 'ball'
          ..name = null
          ..color = new Vector4(0.0, 0.0, 1.0, 1.0)
          ..x = 15
          ..y = 7
      );

      for(int y = 2; y <= 12; y++) {
        stage.components.add(
          new StageComponent()
            ..roll = 'block'
            ..name = null
            ..color = new Vector4(0.0, 0.5, 0.0, 1.0)
            ..x = 10
            ..y = y
        );
      }

      this.startStage(stage);

      window.animationFrame.then(_loop);
    });
  }

  void _setRotationMatrix(Matrix4 rotation) {
    if(_uRotationMatrix != null) {
      _gl.uniformMatrix4fv(_uRotationMatrix, false, rotation.storage );
    }
  }

  void _setDirectionalLight(Vector3 dir) {
    if(_uDirectionalLight != null) {
      _gl.uniform3fv(_uDirectionalLight, dir.storage );
    }
  }

  void _setColor(Vector4 color) {
    if(_uColor != null) {
      _gl.uniform4fv(_uColor, color.storage );
    }
  }

  void _setModelMatrix(Matrix4 model) {
    Matrix4 modelView = _view * model;
    if(_uMVMatrix != null) {
      _gl.uniformMatrix4fv(_uMVMatrix, false, modelView.storage );
    }
  }

  void _setProjectionMatrix(){
    if(_uPMatrix != null) {
      _gl.uniformMatrix4fv(_uPMatrix, false, _projection.storage);
    }
  }

  Vector2 _toScreen(Vector3 position, Matrix4 model) {
    Vector4 v4 = new Vector4(position.x, position.y, position.z, 1.0);

    Matrix4 mvp = new Matrix4.identity()
      ..multiply(_projection)
      ..multiply(_view)
      ..multiply(model);

    v4 = mvp * v4;
    double w = v4.w;
    return new Vector2(v4.x / w, v4.y / w);
  }

  void _drawMesh(Mesh mesh, int numItems) {
    Matrix4 model = new Matrix4.identity();
    Matrix4 rotation = new Matrix4.identity();

    Vector3 position = mesh.position;

    model.setTranslation(position);
    model.multiply(rotation);

    _setModelMatrix(model);
    _setRotationMatrix(rotation);
    _setColor(mesh.color);

    _gl.drawArrays(GL.TRIANGLES, 0, numItems);
  }

  void _loop(num deltaT) {
    window.animationFrame.then(_loop);

    double angle = Math.atan2(_mouse.y, _mouse.x);
    double d = _mouse.length;
    double c = Math.cos(angle);
    double s = Math.sin(angle);

    this.gravity.x = c * d * 10.0;
    this.gravity.y = s * d * 10.0;

    this.light = (
      new Vector3( _mouse.x, _mouse.y, -Math.sqrt(Math.max(1.0 - _mouse.length2, 0.0)) )..normalize()
    ) * -1.0;

    _world.step(1.0 / 60.0, 10, 10);

    _frame = _frame + 1;

    if(this.skipFrame && (!(_frame % 2 == 0))) {
      return;
    }

    _gl.useProgram(_program);
    _gl.viewport(0, 0, _canvas.width, _canvas.height);

    _gl.enable(GL.DEPTH_TEST);
    _gl.clearColor(0.5, 0.5, 0.5, 1.0);
    _gl.clear(GL.DEPTH_BUFFER_BIT | GL.COLOR_BUFFER_BIT);

    _setDirectionalLight(light);
    _setProjectionMatrix();

    if(_aPosition != -1) {
      _gl.bindBuffer(GL.ARRAY_BUFFER, _boxPositionBuffer);
      _gl.vertexAttribPointer(_aPosition, 3, GL.FLOAT, false, 0, 0);
    }

    if(_aNormal != -1) {
      _gl.bindBuffer(GL.ARRAY_BUFFER, _boxNormalBuffer);
      _gl.vertexAttribPointer(_aNormal, 3, GL.FLOAT, false, 0, 0);
    }

    int numBoxItems = ( _boxPositions.length / 3).floor();
    [_rigidBoxList, _staticBoxList].forEach((List<Mesh> boxMeshList){
      boxMeshList.forEach((Mesh boxMesh){
        _drawMesh(boxMesh, numBoxItems);
      });
    });

    if(_aPosition != -1) {
      _gl.bindBuffer(GL.ARRAY_BUFFER, _spherePositionBuffer);
      _gl.vertexAttribPointer(_aPosition, 3, GL.FLOAT, false, 0, 0);
    }

    if(_aNormal != -1) {
      _gl.bindBuffer(GL.ARRAY_BUFFER, _sphereNormalBuffer);
      _gl.vertexAttribPointer(_aNormal, 3, GL.FLOAT, false, 0, 0);
    }

    int numSphereItems = ( _spherePositions.length / 3).floor();
    _rigidSphereList.forEach((RigidMesh rigidSphere){
      _drawMesh(rigidSphere, numSphereItems);
    });
  }
}
