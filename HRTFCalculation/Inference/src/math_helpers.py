import torch


def get_quaternion_from_rotation_matrix(R:torch.tensor) -> torch.tensor:
    """
    Returns a quaternion from a rotation matrix.

    Args:
        R (np.ndarray): Rotation matrix of shape (Nbatch,N,3,3)
    Returns:
        np.ndarray: Quaternion of shape (Nbatch,N,4)
    """
    # Shepperd's method: pick the numerically largest of w, x, y, z as the pivot
    # so the division never happens by a value close to zero (the plain
    # trace-based formula breaks down for rotations near 180 degrees).
    r00, r11, r22 = R[..., 0, 0], R[..., 1, 1], R[..., 2, 2]
    trace = r00 + r11 + r22
    candidates = torch.stack((trace, r00, r11, r22), dim=-1)
    pivot = torch.argmax(candidates, dim=-1)

    # Each row is (w, x, y, z) scaled by 4 * pivot component.
    from_w = torch.stack((1 + trace, R[..., 2, 1] - R[..., 1, 2], R[..., 0, 2] - R[..., 2, 0], R[..., 1, 0] - R[..., 0, 1]), dim=-1)
    from_x = torch.stack((R[..., 2, 1] - R[..., 1, 2], 1 + r00 - r11 - r22, R[..., 0, 1] + R[..., 1, 0], R[..., 0, 2] + R[..., 2, 0]), dim=-1)
    from_y = torch.stack((R[..., 0, 2] - R[..., 2, 0], R[..., 0, 1] + R[..., 1, 0], 1 - r00 + r11 - r22, R[..., 1, 2] + R[..., 2, 1]), dim=-1)
    from_z = torch.stack((R[..., 1, 0] - R[..., 0, 1], R[..., 0, 2] + R[..., 2, 0], R[..., 1, 2] + R[..., 2, 1], 1 - r00 - r11 + r22), dim=-1)
    scaled = torch.stack((from_w, from_x, from_y, from_z), dim=-2)
    scaled = torch.gather(scaled, -2, pivot[..., None, None].expand(*pivot.shape, 1, 4)).squeeze(-2)
    pivot_value = torch.gather(scaled, -1, pivot[..., None])
    Q = scaled / (2 * torch.sqrt(pivot_value))
    # Keep the previous convention w >= 0 (q and -q are the same rotation).
    Q = torch.where(Q[..., :1] < 0, -Q, Q)
    return Q


def normalize_vector(vec: torch.tensor) -> torch.tensor:
    batch = vec.shape[0]
    vec_mag = torch.sqrt(vec.pow(2).sum(2))# batch
    # gpu = vec_mag.get_device()
    eps = torch.autograd.Variable(torch.FloatTensor([1e-8])).to(vec.device)
    vec_mag = torch.max(vec_mag, eps)
    vec_mag = vec_mag[..., None].expand(batch, vec.shape[1], 3)
    vec = vec/vec_mag
    return vec

def compute_rotation_matrix_from_ortho6d(poses: torch.tensor) -> torch.tensor:
    x_raw = poses[:, :, 0:3]
    y_raw = poses[:, :, 3:6]

    x = normalize_vector(x_raw)
    z = torch.linalg.cross(x, y_raw, dim=2)
    z = normalize_vector(z)
    y = torch.linalg.cross(z, x, dim=2)

    x = x.view(-1,poses.shape[1],3,1)
    y = y.view(-1,poses.shape[1],3,1)
    z = z.view(-1,poses.shape[1],3,1)
    matrix = torch.cat((x,y,z), 3)
    return matrix