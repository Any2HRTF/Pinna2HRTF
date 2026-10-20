import torch


def get_quaternion_from_rotation_matrix(R:torch.tensor) -> torch.tensor:
    """
    Returns a quaternion from a rotation matrix.

    Args:
        R (np.ndarray): Rotation matrix of shape (Nbatch,N,3,3)
    Returns:
        np.ndarray: Quaternion of shape (Nbatch,N,4)
    """
    Q = torch.zeros((R.shape[0],R.shape[1],4), dtype=R.dtype, device=R.device)

    Q[...,0] = torch.sqrt(1 + R[...,0,0] + R[...,1,1] + R[...,2,2]) / 2
    Q[...,1] = (R[...,2,1] - R[...,1,2]) / (4*Q[...,0])
    Q[...,2] = (R[...,0,2] - R[...,2,0]) / (4*Q[...,0])
    Q[...,3] = (R[...,1,0] - R[...,0,1]) / (4*Q[...,0])
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