import 'dart:typed_data';
import 'dart:ui';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:agora_rtc_engine_example/config/agora.config.dart' as config;
import 'package:agora_rtc_engine_example/components/example_actions_widget.dart';
import 'package:agora_rtc_engine_example/components/log_sink.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

/// PushVideoFrame Example
class PushVideoFrameVideoTrack extends StatefulWidget {
  /// Construct the [PushVideoFrame]
  const PushVideoFrameVideoTrack({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _State();
}

class _State extends State<PushVideoFrameVideoTrack> {
  late final RtcEngine _engine;
  bool _isReadyPreview = false;

  bool isJoined = false, switchCamera = true, switchRender = true;
  Set<int> remoteUid = {};
  late TextEditingController _controller;

  late List<CameraDescription> _cameras;
  int _camIndex = 0;
  int _customVideoTrackId = -1;
  CameraController? _cameraController;
  bool isCameraPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: config.channelId);

    _initEngine();
  }

  @override
  void dispose() {
    super.dispose();
    _dispose();
  }

  Future<void> _dispose() async {
    await _engine.leaveChannel();
    await _engine.release();
  }

  Future<void> _initEngine() async {
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(
        appId: config.appId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting));
    await _engine.setLogFilter(LogFilterType.logFilterError);

    _engine.registerEventHandler(RtcEngineEventHandler(
      onError: (ErrorCodeType err, String msg) {
        logSink.log('[onError] err: $err, msg: $msg');
      },
      onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
        logSink.log(
            '[onJoinChannelSuccess] connection: ${connection.toJson()} elapsed: $elapsed');
        setState(() {
          isJoined = true;
        });
      },
      onUserJoined: (RtcConnection connection, int rUid, int elapsed) {
        logSink.log(
            '[onUserJoined] connection: ${connection.toJson()} remoteUid: $rUid elapsed: $elapsed');
        setState(() {
          remoteUid.add(rUid);
        });
      },
      onUserOffline:
          (RtcConnection connection, int rUid, UserOfflineReasonType reason) {
        logSink.log(
            '[onUserOffline] connection: ${connection.toJson()}  rUid: $rUid reason: $reason');
        setState(() {
          remoteUid.removeWhere((element) => element == rUid);
        });
      },
      onLeaveChannel: (RtcConnection connection, RtcStats stats) {
        logSink.log(
            '[onLeaveChannel] connection: ${connection.toJson()} stats: ${stats.toJson()}');
        setState(() {
          isJoined = false;
          remoteUid.clear();
        });
      },
    ));
    WidgetsFlutterBinding.ensureInitialized();
    _cameras = await getCameras();
    var _granted = await syncPermissionStatus();
    if (_granted == true) {
      setState(() {
        isCameraPermissionGranted = true;
      });
    }

    _customVideoTrackId = await _engine.createCustomVideoTrack();
    if (_customVideoTrackId > 0) {}

    await _engine.enableVideo();

    VideoEncoderConfiguration videoConfig = VideoEncoderConfiguration(
      codecType: VideoCodecType.videoCodecVp9,
      dimensions: const VideoDimensions(width: 1280, height: 720),
      frameRate: FrameRate.frameRateFps15.value(),
      bitrate: 0,
      minBitrate: -1,
      orientationMode: OrientationMode.orientationModeFixedLandscape,
      degradationPreference: DegradationPreference.maintainQuality,
      mirrorMode: VideoMirrorModeType.videoMirrorModeDisabled,
    );
    await _engine.setVideoEncoderConfiguration(videoConfig);
    setState(() {
      _isReadyPreview = true;
    });
  }

  Future<List<CameraDescription>> getCameras() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      print(cameras
          .where((camera) => camera.lensDirection != CameraLensDirection.front)
          .toList());
      return cameras
          .where((camera) => camera.lensDirection != CameraLensDirection.front)
          .toList();
    } on CameraException catch (e) {
      return [];
      print('Error in fetching the cameras: $e');
    }
  }

  Future<void> onNewCameraSelected(CameraDescription cameraDescription) async {
    final CameraController newController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController?.stopImageStream();
      await _cameraController?.dispose();
      await newController.initialize();
      await newController
          .lockCaptureOrientation(DeviceOrientation.landscapeRight);
      _cameraController = newController;
      await newController.startImageStream((CameraImage image) {
        print(image.width);
        _engine.getMediaEngine().pushVideoFrame(
            videoTrackId: _customVideoTrackId,
            frame: ExternalVideoFrame(
                type: VideoBufferType.videoBufferRawData,
                format: VideoPixelFormat.videoPixelI420,
                buffer: Uint8List.fromList(
                    image.planes.expand((plane) => plane.bytes).toList()),
                stride: image.height,
                height: image.height,
                timestamp: DateTime.now().millisecondsSinceEpoch));
      });
    } on CameraException catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> _joinChannel() async {
    await _engine.joinChannel(
        token: config.token,
        channelId: _controller.text,
        uid: config.uid,
        options: ChannelMediaOptions(
            autoSubscribeVideo: false,
            customVideoTrackId: _customVideoTrackId,
            publishCustomVideoTrack: true,
            publishCameraTrack: false,
            channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
            clientRoleType: ClientRoleType.clientRoleBroadcaster));
    await onNewCameraSelected(_cameras[_camIndex]);
  }

  Future<void> _leaveChannel() async {
    await _engine.leaveChannel();
  }

  Future<bool> syncPermissionStatus() async {
    await Permission.camera.request();
    PermissionStatus status = await Permission.camera.status;
    if (status.isDenied) {
      if (kDebugMode) {
        print('Camera Permission: DENIED');
      }
      return false;
    } else {
      if (kDebugMode) {
        print('Camera Permission: GRANTED');
      }
      setState(() {
        isCameraPermissionGranted = true;
      });
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExampleActionsWidget(
      displayContentBuilder: (context, isLayoutHorizontal) {
        if (!_isReadyPreview || _cameraController == null) {
          return Container();
        } else {
          return CameraPreview(_cameraController!);
        }
        ;
      },
      actionsBuilder: (context, isLayoutHorizontal) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(hintText: 'Channel ID'),
            ),
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: ElevatedButton(
                    onPressed: isJoined ? _leaveChannel : _joinChannel,
                    child: Text('${isJoined ? 'Leave' : 'Join'} channel'),
                  ),
                )
              ],
            ),
          ],
        );
      },
    );
  }
}
