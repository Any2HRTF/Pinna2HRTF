from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.optimize import brentq, minimize_scalar


C = 343.0
SOURCE_DISTANCE = 100.0


def source_unit(az_deg: float, el_deg: float) -> np.ndarray:
    az, el = np.deg2rad([az_deg, el_deg])
    return np.array([np.cos(el) * np.sin(az),
                     np.cos(el) * np.cos(az), np.sin(el)])


def yaw_rotate(v: np.ndarray, yaw_deg: float) -> np.ndarray:

    a = np.deg2rad(yaw_deg)
    return np.array([np.cos(a) * v[0] + np.sin(a) * v[1],
                     -np.sin(a) * v[0] + np.cos(a) * v[1], v[2]])


def zolzer_ms(az_deg: float, el_deg: float) -> float:

    return (1.2 * (180.0 - az_deg) / 180.0
            * (1.0 - 0.00004
               * ((el_deg - 80.0) * 180.0 / (180.0 + az_deg)) ** 2))


def interaural_polar(az_deg: float, el_deg: float) -> tuple[float, float]:


    x, y, z = source_unit(az_deg, el_deg)
    if np.hypot(y, z) < 1e-12:
        return 90.0, np.nan
    return (float(np.rad2deg(np.arcsin(np.clip(x, -1.0, 1.0)))),
            float(np.rad2deg(np.arctan2(z, y))))


def zolzer_world_ms(az_deg: float, el_deg: float) -> float:

    alpha, beta = interaural_polar(az_deg, el_deg)
    if (not np.isfinite(beta) or not (0.0 <= alpha <= 60.0 + 1e-9)
            or not (-100.0 <= beta <= 100.0)):
        return np.nan
    value = zolzer_ms(alpha, beta)
    return value if value >= 0.0 else np.nan


@dataclass(frozen=True)
class AlgaziGeometry:
    a: float = 0.087
    b: float = 0.169
    h: float = 0.053

    @property
    def ear(self) -> np.ndarray:
        return np.array([self.a, 0.0, self.b + self.h + self.a])


ALG = AlgaziGeometry()


@dataclass(frozen=True)
class AlgaziReflection:


    has_reflection: bool
    delay_ms: float
    direction_xyz: np.ndarray | None
    reflection_point_xyz: np.ndarray | None
    azimuth_deg: float
    elevation_deg: float
    observation_offset_deg: float
    separation_deg: float


def algazi_reflection(az_deg: float, el_deg: float,
                      geom: AlgaziGeometry = ALG,
                      ear: str = "right") -> AlgaziReflection:


    if ear not in ("right", "left"):
        raise ValueError("ear must be 'right' or 'left'")
    s = source_unit(az_deg, el_deg)
    side = 1.0 if ear == "right" else -1.0
    dvec = np.array([side * geom.a, 0.0,
                     geom.b + geom.h + geom.a])
    d = np.linalg.norm(dvec)
    A = d / geom.b
    eps = np.arcsin(np.clip(np.dot(dvec, s) / d, -1.0, 1.0))
    alpha_max = np.arccos(1.0 / A)
    if eps <= -alpha_max + 1e-11:
        return AlgaziReflection(False, np.nan, None, None,
                                np.nan, np.nan, np.nan, np.nan)

    def residual(alpha: float) -> float:
        beta = np.arctan2(np.sin(alpha), A - np.cos(alpha))
        return np.pi / 2.0 - 2.0 * alpha - beta - eps

    alpha = brentq(residual, 0.0, alpha_max, xtol=1e-14)
    beta = np.arctan2(np.sin(alpha), A - np.cos(alpha))
    psi = alpha + beta
    f = np.sqrt(geom.b**2 + d**2 - 2.0 * geom.b * d * np.cos(alpha))


    delay_ms = 2000.0 * f * np.cos(psi)**2 / C

    perpendicular = s - np.dot(dvec, s) * dvec / d**2
    norm = np.linalg.norm(perpendicular)
    if norm < 1e-12:


        bvec = geom.b * dvec / d
    else:
        bvec = (geom.b * np.cos(alpha) * dvec / d
                + geom.b * np.sin(alpha) * perpendicular / norm)
    r = (bvec - dvec) / np.linalg.norm(bvec - dvec)
    head_normal = np.array([side, 0.0, 0.0])
    theta_direct = np.arccos(np.clip(np.dot(head_normal, s), -1, 1))
    theta_reflect = np.arccos(np.clip(np.dot(head_normal, r), -1, 1))
    horizontal = np.hypot(r[0], r[1])
    az_reflect = (float(np.rad2deg(np.arctan2(r[0], r[1])))
                  if horizontal >= 1e-12 else np.nan)
    el_reflect = float(np.rad2deg(np.arcsin(np.clip(r[2], -1, 1))))
    separation = float(np.rad2deg(np.arccos(np.clip(np.dot(s, r), -1, 1))))
    return AlgaziReflection(
        True, float(delay_ms), r, bvec, az_reflect, el_reflect,
        float(np.rad2deg(theta_reflect - theta_direct)), separation)


def algazi_result(az_deg: float, el_deg: float,
                  geom: AlgaziGeometry = ALG) -> tuple[float, float]:

    result = algazi_reflection(az_deg, el_deg, geom)
    return result.delay_ms, result.observation_offset_deg


def algazi_left_result(az_deg: float, el_deg: float,
                       geom: AlgaziGeometry = ALG) -> tuple[float, float]:

    result = algazi_reflection(az_deg, el_deg, geom, ear="left")
    return result.delay_ms, result.observation_offset_deg


@dataclass(frozen=True)
class ReijniersGeometry:

    rh: float = 0.07
    phi_deg: float = 7.0
    neck: float = 0.18
    rx: float = 0.25
    ry: float = 0.06
    rz: float = 0.17

    @property
    def semiaxes(self) -> np.ndarray:
        return np.array([self.rx, self.ry, self.rz])

    @property
    def head_centre(self) -> np.ndarray:
        phi = np.deg2rad(self.phi_deg)


        return np.array([0.0, -self.neck * np.sin(phi),
                         self.rz + self.neck * np.cos(phi)])

    @property
    def ear(self) -> np.ndarray:
        return self.head_centre + np.array([self.rh, 0.0, 0.0])


REI = ReijniersGeometry()


def segment_intersects_ellipsoid(p: np.ndarray, q: np.ndarray,
                                 radii: np.ndarray) -> bool:

    p2, v = p / radii, (q - p) / radii
    aa, bb, cc = np.dot(v, v), 2 * np.dot(p2, v), np.dot(p2, p2) - 1
    disc = bb * bb - 4 * aa * cc
    if disc < 0:
        return False
    roots = [(-bb - np.sqrt(disc)) / (2 * aa),
             (-bb + np.sqrt(disc)) / (2 * aa)]
    return any(1e-8 < x < 1 - 1e-8 for x in roots)


def path_to_ear_around_head(p: np.ndarray, head: np.ndarray,
                            ear: np.ndarray, radius: float) -> float:

    v = p - head
    dist = np.linalg.norm(v)
    if dist <= radius:
        raise ValueError("Path endpoint lies inside head sphere")
    normal = (ear - head) / radius
    delta = np.arccos(np.clip(np.dot(v, normal) / dist, -1.0, 1.0))
    tangent_angle = np.arccos(radius / dist)
    if delta <= tangent_angle + 1e-12:
        return float(np.linalg.norm(p - ear))
    return float(np.sqrt(dist * dist - radius * radius)
                 + radius * (delta - tangent_angle))


def reijniers_result(az_deg: float, el_deg: float,
                     geom: ReijniersGeometry = REI,
                     head_yaw_deg: float = 0.0,
                     source_distance_m: float = SOURCE_DISTANCE,
                     head_path_correction: bool = True) -> float:


    if abs(head_yaw_deg) > 1e-12:
        raise NotImplementedError(
            "Nonzero head-above-torso yaw is not independently validated")
    if source_distance_m <= 0 or not np.isfinite(source_distance_m):
        raise ValueError("source_distance_m must be positive and finite")
    s = yaw_rotate(source_unit(az_deg, el_deg), head_yaw_deg)


    joint = np.array([0.0, 0.0, geom.rz])
    head = joint + yaw_rotate(geom.head_centre - joint, head_yaw_deg)
    ear = head + yaw_rotate(np.array([geom.rh, 0.0, 0.0]), head_yaw_deg)
    radii = geom.semiaxes
    source = head + source_distance_m * s
    if segment_intersects_ellipsoid(ear, source, radii):
        return 0.0


    ep, sp = ear / radii, source / radii
    ds, de = np.linalg.norm(sp), np.linalg.norm(ep)
    if min(ds, de) <= 1.0:
        raise ValueError("Source and ear must be outside the torso ellipsoid")
    u = sp / ds
    perp = ep - np.dot(ep, u) * u
    if np.linalg.norm(perp) < 1e-12 * de:


        if np.dot(ep, u) < 0:
            return 0.0
        tp = u
    else:
        v = perp / np.linalg.norm(perp)
        beta = np.arctan2(np.dot(ep, v), np.dot(ep, u))


        source_halfwidth = np.arccos(1.0 / ds)
        ear_halfwidth = np.arccos(1.0 / de)
        lower = max(-source_halfwidth, beta - ear_halfwidth)
        upper = min(source_halfwidth, beta + ear_halfwidth)
        if lower > upper + 1e-12:
            return 0.0
        if lower > upper:
            lower = upper = (lower + upper) / 2.0

        def point(gamma: float) -> np.ndarray:
            return np.cos(gamma) * u + np.sin(gamma) * v

        def scaled_length(gamma: float) -> float:
            surface = point(gamma)

            return (np.linalg.norm(sp - surface) - ds
                    + np.linalg.norm(ep - surface))


        grid = np.linspace(lower, upper, 65)
        values = np.array([scaled_length(g) for g in grid])
        candidates = [(float(values[0]), float(grid[0])),
                      (float(values[-1]), float(grid[-1]))]
        for i in range(1, len(grid) - 1):
            if values[i] <= values[i-1] and values[i] <= values[i+1]:
                optimum = minimize_scalar(
                    scaled_length, bounds=(grid[i-1], grid[i+1]),
                    method="bounded", options={"xatol": 1e-13})
                candidates.append((float(optimum.fun), float(optimum.x)))
        tp = point(min(candidates, key=lambda item: item[0])[1])
    t = radii * tp


    direct = (path_to_ear_around_head(source, head, ear, geom.rh)
              if head_path_correction else np.linalg.norm(source - ear))
    reflected = np.linalg.norm(source - t) + (
        path_to_ear_around_head(t, head, ear, geom.rh)
        if head_path_correction else np.linalg.norm(t - ear))
    delay_ms = 1000.0 * (reflected - direct) / C
    if delay_ms < -1e-7:
        raise ArithmeticError("Reflected path shorter than direct path")
    return max(0.0, delay_ms)


def reijniers_left_result(az_deg: float, el_deg: float,
                          geom: ReijniersGeometry = REI,
                          source_distance_m: float = SOURCE_DISTANCE,
                          head_path_correction: bool = True) -> float:

    return reijniers_result(-az_deg, el_deg, geom,
                            source_distance_m=source_distance_m,
                            head_path_correction=head_path_correction)


@dataclass(frozen=True)
class TorsoReflectionEstimate:


    has_reflection: bool
    delay_s: float
    direction_xyz: np.ndarray | None
    reflected_azimuth_deg: float
    reflected_elevation_deg: float
    angle_offset_deg: float
    reason: str


def estimate_torso_reflection(
    az_deg: float,
    el_deg: float,
    *,
    ear: str = "right",
    delay_model: str = "algazi",
    source_distance_m: float = SOURCE_DISTANCE,
) -> TorsoReflectionEstimate:


    if ear not in ("right", "left"):
        raise ValueError("ear must be 'right' or 'left'")
    if delay_model not in ("algazi", "reijniers"):
        raise ValueError("delay_model must be 'algazi' or 'reijniers'")
    incidence = algazi_reflection(az_deg, el_deg, ear=ear)
    if not incidence.has_reflection:
        return TorsoReflectionEstimate(
            False, np.nan, None, np.nan, np.nan, np.nan,
            "no Algazi specular ray")
    if delay_model == "algazi":
        delay_ms = incidence.delay_ms
    else:
        delay_ms = (reijniers_result(az_deg, el_deg,
                                     source_distance_m=source_distance_m)
                    if ear == "right" else
                    reijniers_left_result(az_deg, el_deg,
                                           source_distance_m=source_distance_m))
    if delay_ms <= 0:
        return TorsoReflectionEstimate(
            False, np.nan, None, np.nan, np.nan, np.nan,
            "no positive torso reflection delay")
    return TorsoReflectionEstimate(
        True, float(delay_ms / 1000.0), incidence.direction_xyz,
        incidence.azimuth_deg, incidence.elevation_deg,
        incidence.observation_offset_deg, "")
