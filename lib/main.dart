import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:xml/xml.dart' as xml;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Georef PDF Map',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MapHomePage(),
    );
  }
}

class MapHomePage extends StatefulWidget {
  const MapHomePage({super.key});

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> {
  // Map controller
  final MapController _mapController = MapController();
  
  // Location tracking
  final Location _location = Location();
  LocationData? _currentLocationData;
  LocationData? _previousLocationData;
  StreamSubscription<LocationData>? _positionStreamSubscription;
  bool _centerOnLocation = false;
  bool _rotateToDirection = false;
  
  // Movement tracking for rotation
  static const double _movementThreshold = 6.0; // 6 meters
  double _accumulatedDistance = 0.0;
  
  // PDF overlay
  // ignore: unused_field
  File? _pdfFile;
  List<LatLng> _pdfCorners = [];
  bool _showPdfOverlay = false;
  
  // Saved settings (punch zoom/rotate)
  double? _savedZoom;
  double? _savedRotation;
  
  // Wake lock
  bool _wakeLockEnabled = false;
  
  // Map state
  double _currentRotation = 0.0;
  double _currentZoom = 15.0;
  
  // Location tracking history
  bool _isTracking = false;
  List<LatLng> _locationHistory = [];
  DateTime? _trackingStartTime;
  DateTime? _trackingEndTime;
  List<Map<String, dynamic>> _savedTracks = [];
  
  // Track statistics
  double _totalDistance = 0.0;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _loadSavedTracks();
    _requestPermissions();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _savedZoom = prefs.getDouble('saved_zoom');
      _savedRotation = prefs.getDouble('saved_rotation');
      _wakeLockEnabled = prefs.getBool('wake_lock_enabled') ?? false;
      
      if (_savedZoom != null) {
        _currentZoom = _savedZoom!;
      }
      if (_savedRotation != null) {
        _currentRotation = _savedRotation!;
      }
      if (_wakeLockEnabled) {
        WakelockPlus.enable();
      }
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('saved_zoom', _currentZoom);
    await prefs.setDouble('saved_rotation', _currentRotation);
    await prefs.setBool('wake_lock_enabled', _wakeLockEnabled);
  }
  
  Future<void> _loadSavedTracks() async {
    final prefs = await SharedPreferences.getInstance();
    final String? tracksJson = prefs.getString('saved_tracks');
    if (tracksJson != null) {
      // In a real implementation, you'd parse JSON here
      // For now, we'll just keep it as an empty list
      setState(() {
        _savedTracks = [];
      });
    }
  }
  
  Future<void> _saveTracks() async {
    final prefs = await SharedPreferences.getInstance();
    // In a real implementation, you'd convert tracks to JSON here
    // For now, we'll just save an empty string
    await prefs.setString('saved_tracks', '');
  }

  Future<void> _requestPermissions() async {
    // Location permissions
    Map<ph.Permission, ph.PermissionStatus> statuses = await [
      ph.Permission.location,
      ph.Permission.locationAlways,
      ph.Permission.locationWhenInUse,
      ph.Permission.storage,
    ].request();
    
    // Check if location permission is granted
    if (statuses[ph.Permission.location]!.isGranted) {
      _startLocationTracking();
    } else {
      _showPermissionDialog();
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
          'This app needs location permission to center the map on your position and enable rotation based on movement direction.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              ph.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _startLocationTracking() {
    // Check if service is enabled
    _location.serviceEnabled().then((serviceEnabled) {
      if (!serviceEnabled) {
        _location.requestService().then((serviceEnabledResult) {
          if (!serviceEnabledResult) {
            return;
          }
        });
      }
      
      // Request permission
      _location.hasPermission().then((permissionStatus) {
        if (permissionStatus == PermissionStatus.denied) {
          _location.requestPermission().then((permissionStatusResult) {
            if (permissionStatusResult != PermissionStatus.granted) {
              return;
            }
          });
        }
        
        // Start location stream
        _location.changeSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1, // Update every meter
        );
        
        _positionStreamSubscription = _location.onLocationChanged.listen((LocationData locationData) {
          setState(() {
            _previousLocationData = _currentLocationData;
            _currentLocationData = locationData;
            
            // Handle centering
            if (_centerOnLocation && locationData.latitude != null && locationData.longitude != null) {
              _mapController.move(LatLng(locationData.latitude!, locationData.longitude!), _currentZoom);
            }
            
            // Handle rotation based on movement
            if (_rotateToDirection && _previousLocationData != null && _currentLocationData != null) {
              _handleRotationBasedOnMovement();
            }
            
            // Handle location tracking history
            if (_isTracking && locationData.latitude != null && locationData.longitude != null) {
              _locationHistory.add(LatLng(locationData.latitude!, locationData.longitude!));
            }
          });
        });
      });
    });
  }

  void _handleRotationBasedOnMovement() {
    if (_previousLocationData == null || _currentLocationData == null) return;
    if (_previousLocationData!.latitude == null || _previousLocationData!.longitude == null ||
        _currentLocationData!.latitude == null || _currentLocationData!.longitude == null) return;
    
    double distance = _calculateDistance(
      _previousLocationData!.latitude!,
      _previousLocationData!.longitude!,
      _currentLocationData!.latitude!,
      _currentLocationData!.longitude!,
    );
    
    _accumulatedDistance += distance;
    
    // Only rotate after moving more than 6 meters
    if (_accumulatedDistance >= _movementThreshold) {
      // Calculate bearing
      double bearing = _calculateBearing(
        _previousLocationData!.latitude!,
        _previousLocationData!.longitude!,
        _currentLocationData!.latitude!,
        _currentLocationData!.longitude!,
      );
      
      // Convert bearing to rotation (bearing is in degrees, clockwise from north)
      // Map rotation is in radians, counter-clockwise from east
      setState(() {
        _currentRotation = -bearing * (3.14159265359 / 180.0) - (3.14159265359 / 2.0);
        _accumulatedDistance = 0.0; // Reset for next rotation calculation
      });
      
      // Update map rotation
      _mapController.rotate(_currentRotation);
    }
  }
  
  // Haversine formula for distance calculation
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000; // meters
    double dLat = _degreesToRadians(lat2 - lat1);
    double dLon = _degreesToRadians(lon2 - lon1);
    
    double a = 
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * 
      math.sin(dLon / 2) * math.sin(dLon / 2);
    double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    
    return earthRadius * c;
  }
  
  double _degreesToRadians(double degrees) {
    return degrees * (3.14159265359 / 180.0);
  }
  
  // Calculate bearing between two points
  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    double dLon = _degreesToRadians(lon2 - lon1);
    lat1 = _degreesToRadians(lat1);
    lat2 = _degreesToRadians(lat2);
    
    double y = math.sin(dLon) * math.cos(lat2);
    double x = math.cos(lat1) * math.cos(lat2) * math.cos(dLon) - math.sin(lat1) * math.cos(lat2);
    
    double bearing = math.atan2(y, x) * 180.0 / 3.14159265359;
    return (bearing + 360) % 360; // Normalize to 0-360
  }

  Future<void> _pickPdfFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _pdfFile = File(result.files.single.path!);
        _showPdfOverlay = true;
      });
      
      // For demonstration, we'll create default corners
      // In a real app, you would parse the PDF for georeference information
      // or ask the user to input coordinates
      _setPdfCornersDemo();
    }
  }

  void _setPdfCornersDemo() {
    if (_currentLocationData != null && _currentLocationData!.latitude != null && _currentLocationData!.longitude != null) {
      double lat = _currentLocationData!.latitude!;
      double lng = _currentLocationData!.longitude!;
      
      // Create a 1km x 1km box around current position
      double deltaLat = 0.005; // approximately 500 meters
      double deltaLng = 0.005; // approximately 500 meters (varies by latitude)
      
      setState(() {
        _pdfCorners = [
          LatLng(lat + deltaLat, lng - deltaLng), // Top-left
          LatLng(lat + deltaLat, lng + deltaLng), // Top-right
          LatLng(lat - deltaLat, lng + deltaLng), // Bottom-right
          LatLng(lat - deltaLat, lng - deltaLng), // Bottom-left
        ];
      });
    }
  }

  void _punchZoomAndRotate() {
    setState(() {
      _savedZoom = _currentZoom;
      _savedRotation = _currentRotation;
    });
    _saveSettings();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zoom and rotation saved!')),
    );
  }

  void _restoreZoomAndRotate() {
    if (_savedZoom != null && _savedRotation != null) {
      setState(() {
        _currentZoom = _savedZoom!;
        _currentRotation = _savedRotation!;
      });
      _mapController.move(_mapController.camera.center, _currentZoom);
      _mapController.rotate(_currentRotation);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zoom and rotation restored!')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved zoom/rotation to restore')),
      );
    }
  }

  void _toggleWakeLock() {
    setState(() {
      _wakeLockEnabled = !_wakeLockEnabled;
    });
    
    if (_wakeLockEnabled) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    
    _saveSettings();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Wake lock ${_wakeLockEnabled ? "enabled" : "disabled"}')),
    );
  }
  
  void _toggleTracking() {
    setState(() {
      _isTracking = !_isTracking;
      if (_isTracking) {
        _locationHistory = [];
        _trackingStartTime = DateTime.now();
        _trackingEndTime = null;
        _totalDistance = 0.0;
      } else {
        _trackingEndTime = DateTime.now();
        _calculateTrackStatistics();
      }
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Tracking ${_isTracking ? "started" : "stopped"}')),
    );
  }
  
  void _calculateTrackStatistics() {
    if (_locationHistory.length < 2) return;
    
    double totalDist = 0.0;
    for (int i = 1; i < _locationHistory.length; i++) {
      totalDist += _calculateDistance(
        _locationHistory[i - 1].latitude,
        _locationHistory[i - 1].longitude,
        _locationHistory[i].latitude,
        _locationHistory[i].longitude,
      );
    }
    
    setState(() {
      _totalDistance = totalDist;
    });
  }
  
  Future<void> _saveCurrentTrack() async {
    if (_locationHistory.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not enough location data to save track')),
      );
      return;
    }
    
    final track = {
      'name': 'Track ${DateTime.now().toString().substring(0, 16)}',
      'points': _locationHistory.map((latLng) => {
        'latitude': latLng.latitude,
        'longitude': latLng.longitude,
      }).toList(),
      'distance': _totalDistance,
      'duration': _trackingEndTime != null && _trackingStartTime != null
          ? _trackingEndTime!.difference(_trackingStartTime!).inSeconds
          : 0,
      'startTime': _trackingStartTime?.toIso8601String(),
      'endTime': _trackingEndTime?.toIso8601String(),
    };
    
    setState(() {
      _savedTracks.add(track);
    });
    
    await _saveTracks();
    
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Track saved successfully')),
    );
  }
  
  Future<void> _exportTrackToGPX(Map<String, dynamic> track) async {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('gpx', attributes: {
      'version': '1.1',
      'creator': 'Georef PDF Map App',
      'xmlns': 'http://www.topografix.com/GPX/1/1',
    }, nest: () {
      builder.element('trk', nest: () {
        builder.element('name', nest: track['name']);
        builder.element('trkseg', nest: () {
          for (var point in track['points']) {
            builder.element('trkpt', attributes: {
              'lat': point['latitude'].toString(),
              'lon': point['longitude'].toString(),
            });
          }
        });
      });
    });
    
    final gpxXml = builder.buildDocument().toXmlString(pretty: true);
    
    // Save to app's internal storage (no special permissions needed)
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = '${track['name'].toString().replaceAll(' ', '_')}.gpx';
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(gpxXml);
      
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GPX exported to app storage: $fileName')),
      );
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to export GPX: $e')),
      );
    }
  }
  
  void _showSavedTracksDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saved Tracks'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: _savedTracks.isEmpty
              ? const Center(child: Text('No saved tracks'))
              : ListView.builder(
                  itemCount: _savedTracks.length,
                  itemBuilder: (context, index) {
                    final track = _savedTracks[index];
                    return ListTile(
                      title: Text(track['name']),
                      subtitle: Text(
                        '${(track['distance'] as double).toStringAsFixed(0)}m | '
                        '${(track['duration'] as int).toStringAsFixed(0)}s',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.share),
                            onPressed: () => _exportTrackToGPX(track),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              setState(() {
                                _savedTracks.removeAt(index);
                              });
                              _saveTracks();
                              Navigator.of(context).pop();
                              _showSavedTracksDialog();
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Georef PDF Map'),
        actions: [
          IconButton(
            icon: Icon(_centerOnLocation ? Icons.my_location : Icons.location_searching),
            onPressed: () {
              setState(() {
                _centerOnLocation = !_centerOnLocation;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Center on location ${_centerOnLocation ? "enabled" : "disabled"}')),
              );
            },
            tooltip: 'Center on location',
          ),
          IconButton(
            icon: Icon(_rotateToDirection ? Icons.explore : Icons.navigation),
            onPressed: () {
              setState(() {
                _rotateToDirection = !_rotateToDirection;
                if (!_rotateToDirection) {
                  _accumulatedDistance = 0.0;
                }
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Rotation to direction ${_rotateToDirection ? "enabled" : "disabled"}')),
              );
            },
            tooltip: 'Rotate to movement direction',
          ),
          IconButton(
            icon: Icon(_isTracking ? Icons.fiber_manual_record : Icons.radio_button_checked),
            color: _isTracking ? Colors.red : null,
            onPressed: _toggleTracking,
            tooltip: 'Toggle location tracking',
          ),
          IconButton(
            icon: Icon(_wakeLockEnabled ? Icons.lock : Icons.lock_open),
            onPressed: _toggleWakeLock,
            tooltip: 'Toggle wake lock',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocationData != null && _currentLocationData!.latitude != null && _currentLocationData!.longitude != null
                  ? LatLng(_currentLocationData!.latitude!, _currentLocationData!.longitude!)
                  : const LatLng(55.6761, 12.5683), // Copenhagen as default
              initialZoom: _currentZoom,
              initialRotation: _currentRotation,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapEvent: (MapEvent event) {
                if (event is MapEventMoveEnd) {
                  setState(() {
                    _currentZoom = event.camera.zoom;
                    _currentRotation = event.camera.rotation;
                  });
                }
              },
            ),
            children: [
              // OpenStreetMap tile layer
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.map_app',
              ),
              
              // PDF overlay (simplified as polygon for demo)
              if (_showPdfOverlay && _pdfCorners.length == 4)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _pdfCorners,
                      color: Colors.red.withOpacity(0.3),
                      borderColor: Colors.red,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
              
              // Location tracking history polyline
              if (_locationHistory.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _locationHistory,
                      strokeWidth: 3.0,
                      color: Colors.blue,
                    ),
                  ],
                ),
              
              // Current location marker
              if (_currentLocationData != null && _currentLocationData!.latitude != null && _currentLocationData!.longitude != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_currentLocationData!.latitude!, _currentLocationData!.longitude!),
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.blue,
                        size: 40,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          
          // Control panel
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _pickPdfFile,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('Load PDF'),
                          ),
                          ElevatedButton.icon(
                            onPressed: _punchZoomAndRotate,
                            icon: const Icon(Icons.save),
                            label: const Text('Save View'),
                          ),
                          ElevatedButton.icon(
                            onPressed: _restoreZoomAndRotate,
                            icon: const Icon(Icons.restore),
                            label: const Text('Restore View'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _isTracking && _locationHistory.length >= 2 ? _saveCurrentTrack : null,
                            icon: const Icon(Icons.add_location_alt),
                            label: const Text('Save Track'),
                          ),
                          ElevatedButton.icon(
                            onPressed: _savedTracks.isNotEmpty ? _showSavedTracksDialog : null,
                            icon: const Icon(Icons.list),
                            label: const Text('Tracks'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Zoom: ${_currentZoom.toStringAsFixed(2)}x | Rotation: ${(_currentRotation * 180 / 3.14159265359).toStringAsFixed(1)}°',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_currentLocationData != null && _currentLocationData!.latitude != null && _currentLocationData!.longitude != null)
                      Text(
                        'Pos: ${_currentLocationData!.latitude!.toStringAsFixed(6)}, ${_currentLocationData!.longitude!.toStringAsFixed(6)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (_isTracking)
                      Text(
                        'Tracking: ${_locationHistory.length} points | ${_totalDistance.toStringAsFixed(0)}m',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}