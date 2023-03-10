import '../clip/antimeridian.dart';
import '../clip/circle.dart';
import '../clip/rectangle.dart';
import '../compose.dart';
import '../identity.dart';
import '../math.dart';
import '../raw.dart';
import '../rotation.dart';
import '../stream.dart';
import '../transform.dart';
import 'conic_equal_area.dart';
import 'fit.dart' as fit;
import 'resample.dart';

final _transformRadians = GeoTransform(point: (stream, p) {
  stream.point([p[0] * radians, p[1] * radians]);
});

GeoTransform _transformRotate(GeoRawTransform rotate) =>
    GeoTransform(point: (stream, p) => stream.point(rotate.forward(p)));

GeoRawTransform _scaleTranslate(
        double k, double dx, double dy, int sx, int sy) =>
    GeoRawTransform((p) => [dx + k * (p[0] * sx), dy - k * (p[1] * sy)],
        (p) => [(p[0] - dx) / k * sx, (dy - p[1]) / k * sy]);

GeoRawTransform _scaleTranslateRotate(
    double k, double dx, double dy, int sx, int sy, double alpha) {
  if (alpha == 0) return _scaleTranslate(k, dx, dy, sx, sy);
  var cosAlpha = cos(alpha),
      sinAlpha = sin(alpha),
      a = cosAlpha * k,
      b = sinAlpha * k,
      ai = cosAlpha / k,
      bi = sinAlpha / k,
      ci = (sinAlpha * dy - cosAlpha * dx) / k,
      fi = (sinAlpha * dx + cosAlpha * dy) / k;
  return GeoRawTransform((p) {
    final x = p[0] * sx, y = p[1] * sy;
    return [a * x - b * y + dx, dy - b * x - a * y];
  }, (p) {
    final x = p[0], y = p[1];
    return [sx * (ai * x - bi * y + ci), sy * (fi - bi * x - ai * y)];
  });
}

/// A projection wrapper to mutate as needed.
class GeoProjectionMutator<T> {
  final GeoRawTransform Function(T) _projectAt;
  final GeoProjection _projection;

  /// Constructs a new projection from the specified raw transform [factory] and
  /// returns a *mutate* function to call whenever the raw transform changes.
  ///
  /// The [factory] must return a raw transform. The returned *mutate* function
  /// returns the wrapped projection. For example, a conic projection typically
  /// has two configurable parallels. A suitable factory function, such as
  /// [geoConicEqualAreaRaw], would have the form:
  ///
  /// ```dart
  ///   // y0 and y1 represent two parallels
  ///   GeoRawTransform conicFactory(phi) => GeoRawTransform((p) => [..., ...]);
  /// ```
  ///
  /// Using [GeoProjectionMutator], you can implement a standard projection that
  /// allows the parallels to be changed, reassigning the raw projection used
  /// internally by [GeoProjection]:
  ///
  /// ```dart
  ///   class ConicCustom extends GeoProjection {
  ///     double phi0, phi1;
  ///     late GeoProjectionMutator mutate;
  ///
  ///     factory ConicCustom() => ConicCustom._(29.5, 45.5);
  ///
  ///     ConicCustom._(this.phi0, this.phi1)
  ///         : super(conicFactory([phi0, phi1])) {
  ///       mutate = GeoProjectionMutator(conicFactory, this);
  ///     }
  ///
  ///     List<double> get parallels => [_phi0, _phi1];
  ///     set parallels(List<double> _) => _m([_phi0 = _, _phi1 = _]);
  ///   }
  /// ```
  ///
  /// When creating a mutable projection, the mutate function is typically not
  /// exposed.
  GeoProjectionMutator(
      GeoRawTransform Function(T) factory, GeoProjection projection)
      : _projectAt = factory,
        _projection = projection;

  call(T x) {
    _projection._project = _projectAt(x);
    return _projection._recenter();
  }
}

/// Projections transform spherical polygonal geometry to planar polygonal
/// geometry.
///
/// D3 provides implementations of several classes of standard projections:
///
/// * Azimuthal
/// * Composite
/// * Conic
/// * Cylindrical
///
/// You can implement custom projections using [GeoProjection] or
/// [GeoProjectionMutator].
class GeoProjection implements GeoRawTransform, GeoTransform {
  GeoRawTransform _project;
  double _k = 150, // scale
      _x = 480,
      _y = 250, // translate
      _lambda = 0,
      _phi = 0, // center
      _deltaLambda = 0,
      _deltaPhi = 0,
      _deltaGamma = 0, // pre-rotate
      _alpha = 0; // post-rotate angle
  int _sx = 1, // reflectX
      _sy = 1; // reflectY
  double? _theta; // pre-clip angle
  GeoStream Function(GeoStream) _preclip = geoClipAntimeridian;
  double? _x0, _y0, _x1, _y1; // post-clip extent
  GeoStream Function(GeoStream) _postclip = identity;
  double _delta2 = 0.5; // precision
  late GeoStream Function(GeoStream) _projectResample;
  late GeoRawTransform _rotate, _projectTransform, _projectRotateTransform;
  GeoStream? _cache, _cacheStream;

  /// Constructs a new projection from the specified raw projection, [project].
  /// The [project] forward function takes the *longitude* and *latitude* of a
  /// given point in [radians](http://mathworld.wolfram.com/Radian.html), often
  /// referred to as *lambda* (λ) and *phi* (φ), and returns a two-element array
  /// \[*x*, *y*\] representing its unit projection. The [project] forward
  /// function does not need to scale or translate the point, as these are
  /// applied automatically by [scale], [translate], and [center]. Likewise, the
  /// [project] forward function does not need to perform any spherical
  /// rotation, as [rotate] is applied prior to projection.
  ///
  /// For example, a spherical Mercator projection can be implemented as:
  ///
  /// ```dart
  ///   var mercator = GeoProjection(GeoRawTransform((p) {
  ///     return [p[0], log(tan(pi / 4 + p[1] / 2))];
  ///   }));
  /// ```
  ///
  /// If the [project] raw transform has a non-null backward function, the
  /// returned projection will also have non-null [backward].
  GeoProjection(GeoRawTransform project) : _project = project {
    _recenter();
  }

  /// Returns a new array \[*x*, *y*\] (typically in pixels) representing the
  /// projected point of the given *point*.
  ///
  /// The point must be specified as a two-element array
  /// \[*longitude*, *latitude*\] in degrees. May return a two-element array
  /// filled with [double.nan] if the specified *point* has no defined projected
  /// position, such as when the point is outside the clipping bounds of the
  /// projection.
  @override
  get forward =>
      (p) => _projectRotateTransform.forward([p[0] * radians, p[1] * radians]);

  /// Returns a new array \[*longitude*, *latitude*\] in degrees representing
  /// the unprojected point of the given projected *point*.
  ///
  /// The point must be specified as a two-element array \[*x*, *y*\] (typically
  /// in pixels). May return a two-element array filled with [double.nan] if the
  /// specified *point* has no defined projected position, such as when the
  /// point is outside the clipping bounds of the projection.
  @override
  get backward => _project.backward != null
      ? (p) {
          var l = _projectRotateTransform.backward!(p);
          return [l[0] * degrees, l[1] * degrees];
        }
      : null;

  /// Returns a projection stream for the specified [stream].
  ///
  /// Any input geometry is projected before being streamed to the output
  /// stream. A typical projection involves several geometry transformations:
  /// the input geometry is first converted to radians, rotated on three axes,
  /// clipped to the small circle or cut along the antimeridian, and lastly
  /// projected to the plane with adaptive resampling, scale and translation.
  @override
  GeoStream call(GeoStream stream) => _cache != null && _cacheStream == stream
      ? _cache!
      : _cache = _transformRadians(_transformRotate(_rotate)(
          preclip(_projectResample(postclip(_cacheStream = stream)))));

  /// The projection's spherical clipping.
  GeoStream Function(GeoStream) get preclip => _preclip;
  set preclip(GeoStream Function(GeoStream) _) {
    _preclip = _;
    _theta = null;
    _reset();
  }

  /// The projection's cartesian clipping.
  GeoStream Function(GeoStream) get postclip => _postclip;
  set postclip(GeoStream Function(GeoStream) _) {
    _postclip = _;
    _x0 = _y0 = _x1 = _y1 = null;
    _reset();
  }

  /// The projection's small-circle clipping radius angle in degrees.
  ///
  /// Defaults to `null`, which represents the
  /// [antimeridian cutting](geoClipAntimeridian.html) rather than small-circle
  /// clipping. Small-circle clipping is independent of viewport
  /// clipping via [clipExtent].
  ///
  /// See also [preclip], [geoClipAntimeridian], [geoClipCircle].
  double? get clipAngle => _theta == null ? null : _theta! * degrees;
  set clipAngle(double? _) {
    if (_ != null && _ > 0) {
      preclip = geoClipCircle(_theta = _ * radians);
    } else {
      _theta = null;
      preclip = geoClipAntimeridian;
    }
    _reset();
  }

  /// The projection's viewport clipping extent bounds in pixels.
  ///
  /// The extent bounds are specified as an array \[\[*x₀*, *y₀*\], \[*x₁*,
  /// *y₁*\]\], where *x₀* is the left-side of the viewport, *y₀* is the top,
  /// *x₁* is the right and *y₁* is the bottom. Defaults to `null`, which
  /// represents no viewport clipping. Viewport clipping is independent of
  /// small-circle clipping via [clipAngle].
  ///
  /// See also [postclip], [geoClipRectangle].
  List<List<double>>? get clipExtent => _x0 == null
      ? null
      : [
          [_x0!, _y0!],
          [_x1!, _y1!]
        ];
  set clipExtent(List<List<double>>? _) {
    if (_ == null) {
      _x0 = _y0 = _x1 = _y1 = null;
      _postclip = identity;
      return;
    } else {
      _postclip = geoClipRectangle(
          _x0 = _[0][0], _y0 = _[0][1], _x1 = _[1][0], _y1 = _[1][1]);
    }
    _reset();
  }

  /// The projection's scale factor.
  ///
  /// The scale factor corresponds linearly to the distance between projected
  /// points; however, absolute scale factors are not equivalent across
  /// projections. The default scale factor is projection-specific.
  double get scale => _k;
  set scale(double _) {
    _k = _;
    _recenter();
  }

  /// The projection's translation offset.
  ///
  /// The translation offset is specified as an two-element array \[*tx*,
  /// *ty*\], which determines the pixel coordinates of the projection’s
  /// [center]. The default translation offset places ⟨0°,0°⟩ at the center of a
  /// 960×500 area.
  List<double> get translate => [_x, _y];
  set translate(List<double> _) {
    _x = _[0];
    _y = _[1];
    _recenter();
  }

  /// The projection's center.
  ///
  /// A two-element array of \[*longitude*, *latitude*\] in degrees. Defaults to
  /// ⟨0°,0°⟩.
  List<double> get center => [_lambda * degrees, _phi * degrees];
  set center(List<double> _) {
    _lambda = _[0].remainder(360) * radians;
    _phi = _[1].remainder(360) * radians;
    _recenter();
  }

  /// The projection's
  /// [three-axis spherical rotation](https://observablehq.com/@d3/three-axis-rotation)
  /// angles.
  ///
  /// A two- or three-element array of numbers \[*lambda*, *phi*, *gamma*\]
  /// specifying the rotation angles in degrees about
  /// [each spherical axis](https://observablehq.com/@d3/three-axis-rotation).
  /// (These correspond to
  /// [yaw, pitch and roll](https://en.wikipedia.org/wiki/Aircraft_principal_axes).)
  /// If the rotation angle *gamma* is omitted when setting, it defaults to 0.
  /// See also [GeoRotation]. The default for rotation angles is \[0, 0, 0\].
  List<double> get rotate =>
      [_deltaLambda * degrees, _deltaPhi * degrees, _deltaGamma * degrees];
  set rotate(List<double> _) {
    _deltaLambda = _[0].remainder(360) * radians;
    _deltaPhi = _[1].remainder(360) * radians;
    _deltaGamma = _.length > 2 ? _[2].remainder(360) * radians : 0;
    _recenter();
  }

  /// The projection's post-projection planar rotation angle in degrees.
  ///
  /// Defaults to 0°. Note that it may be faster to rotate during rendering
  /// (e.g., using
  /// [*context*.rotate](https://developer.mozilla.org/docs/Web/API/CanvasRenderingContext2D/rotate))
  /// rather than during projection.
  double get angle => _alpha * degrees;
  set angle(double _) {
    _alpha = _.remainder(360) * radians;
    _recenter();
  }

  /// The projection's x-reflection state.
  ///
  /// Defines whether or not the x-dimension will be reflected (negated) in the
  /// output, which by default is false. This can be useful to display sky and
  /// astronomical data with the orb seen from below: right ascension (eastern
  /// direction) will point to the left when North is pointing up.
  bool get reflectX => _sx < 0;
  set reflectX(bool _) {
    _sx = _ ? -1 : 1;
    _recenter();
  }

  /// The projection's x-reflection state.
  ///
  /// Defines whether or not the x-dimension will be reflected (negated) in the
  /// output, which by default is false. This is especially useful for
  /// transforming from standard
  /// [spatial reference systems](https://en.wikipedia.org/wiki/Spatial_reference_system),
  /// which treat positive
  /// y as pointing up, to display coordinate systems such as Canvas and SVG,
  /// which treat positive y as pointing down.
  bool get reflectY => _sy < 0;
  set reflectY(bool _) {
    _sy = _ ? -1 : 1;
    _recenter();
  }

  /// The projection’s
  /// [adaptive resampling](https://observablehq.com/@d3/adaptive-sampling)
  /// threshold in pixels.
  ///
  /// This value corresponds to the
  /// [Douglas–Peucker](https://en.wikipedia.org/wiki/Ramer%E2%80%93Douglas%E2%80%93Peucker_algorithm)
  /// distance. Defailts to √0.5 ≅ 0.70710…
  double get precision => sqrt(_delta2);
  set precision(double _) {
    _projectResample = resample(_projectTransform, _delta2 = _ * _);
    _reset();
  }

  /// Sets the projection’s [scale] and [translate] to fit the specified GeoJSON
  /// [object] in the center of the given [extent].
  ///
  /// The extent is specified as an array \[\[*x₀*, *y₀*\], \[*x₁*, *y₁*\]\],
  /// where *x₀* is the left side of the bounding box, *y₀* is the top, *x₁* is
  /// the right and *y₁* is the bottom.
  ///
  /// For example, to scale and translate the
  /// [New Jersey State Plane projection](https://bl.ocks.org/mbostock/5126418)
  /// to fit a GeoJSON object nj in the center of a 960×500 bounding box with 20
  /// pixels of padding on each side:
  ///
  /// ```dart
  ///   var projection = GeoTransverseMercator()
  ///     ..rotate = [74 + 30 / 60, -38 - 50 / 60]
  ///     ..fitExtent([
  ///       [20, 20],
  ///       [940, 480]
  ///     ], nj);
  /// ```
  ///
  /// Any [clipExtent] is ignored when determining the new scale and translate.
  /// The [precision] used to compute the bounding box of the given object is
  /// computed at an effective scale of 150.
  void fitExtent(List<List<double>> extent, Map object) {
    fit.extent(this, extent, object);
  }

  /// A convenience method for [fitExtent] where the top-left corner of
  /// the extent is \[0, 0\].
  ///
  /// The following two statements are equivalent:
  ///
  /// ```dart
  ///   projection.fitExtent([
  ///     [0, 0],
  ///     [width, height]
  ///   ], object);
  ///   projection.fitSize([width, height], object);
  /// ```
  void fitSize(List<double> size, Map object) {
    fit.size(this, size, object);
  }

  /// A convenience method for [fitSize] where the height is automatically
  /// chosen from the aspect ratio of object and the given constraint on width.
  void fitWidth(double width, Map object) {
    fit.width(this, width, object);
  }

  /// A convenience method for [fitSize] where the width is
  /// automatically chosen from the aspect ratio of object and the given
  /// constraint on height.
  void fitHeight(double height, Map object) {
    fit.height(this, height, object);
  }

  void _recenter() {
    var center = _scaleTranslateRotate(_k, 0, 0, _sx, _sy, _alpha)
        .forward(_project.forward([_lambda, _phi]));
    var transform = _scaleTranslateRotate(
        _k, _x - center[0], _y - center[1], _sx, _sy, _alpha);
    _rotate = rotateRadians(_deltaLambda, _deltaPhi, _deltaGamma);
    _projectTransform = compose(_project, transform);
    _projectRotateTransform = compose(_rotate, _projectTransform);
    _projectResample = resample(_projectTransform, _delta2);
  }

  void _reset() {
    _cache = _cacheStream = null;
  }
}
