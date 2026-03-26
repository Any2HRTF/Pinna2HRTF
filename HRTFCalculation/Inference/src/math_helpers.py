import torch

def angular_distance_of_normal_vectors_of_the_quaternions(prediction: torch.Tensor,
                                                          gr_truth: torch.Tensor) -> float:
    r""" Calculates the angular distance between the normal vectors of the quaternions.

    Args:
        prediction (torch.Tensor): predicted quaternions
        gr_truth (torch.Tensor): ground truth quaternions

    Returns:
        angles (torch.Tensor): angular distance between the normal vectors of the quaternions

    """

    conj_pred = prediction
    conj_pred[:,1:4,:] = -prediction[:,1:4,:]

    prediction_norm_squared = torch.norm(prediction, p=2, dim=1)**2
    inv_pred = conj_pred / prediction_norm_squared.unsqueeze(1).repeat(1, 4, 1)

    loss_re = gr_truth[:,0,:]*inv_pred[:,0,:] - \
              gr_truth[:,1,:]*inv_pred[:,1,:] - \
              gr_truth[:,2,:]*inv_pred[:,2,:] - \
              gr_truth[:,3,:]*inv_pred[:,3,:]

    loss_x = gr_truth[:, 0, :]*inv_pred[:, 1, :] + \
             gr_truth[:, 1, :]*inv_pred[:, 0, :] + \
             gr_truth[:, 2, :]*inv_pred[:, 3, :] - \
             gr_truth[:, 3, :]*inv_pred[:, 2, :]

    loss_y = gr_truth[:, 0, :]*inv_pred[:, 2, :] + \
             gr_truth[:, 2, :]*inv_pred[:, 0, :] + \
             gr_truth[:, 3, :]*inv_pred[:, 1, :] - \
             gr_truth[:, 1, :]*inv_pred[:, 3, :]

    loss_z = gr_truth[:, 0, :]*inv_pred[:, 3, :] + \
             gr_truth[:, 3, :]*inv_pred[:, 0, :] + \
             gr_truth[:, 1, :]*inv_pred[:, 2, :] - \
             gr_truth[:, 2, :]*inv_pred[:, 1, :]

    loss_x = loss_x.unsqueeze(1)
    loss_y = loss_y.unsqueeze(1)
    loss_z = loss_z.unsqueeze(1)

    vec_norm_squared = loss_x*loss_x + loss_y*loss_y + loss_z*loss_z
    vec_norm = torch.squeeze(
                torch.sqrt(torch.max(vec_norm_squared, torch.ones_like(vec_norm_squared)*1e-10)))
    angles = (2*torch.atan2(vec_norm, loss_re)) / (2*torch.pi)

    return angles

def quaternion_norm(quaternion: torch.Tensor) -> torch.Tensor:
    r""" Calculates the norm of the quaternions.

    Args:
        quaternion (torch.Tensor): quaternion

    Returns:
        norm (torch.Tensor): norm of the quaternion

    """

    return torch.norm(quaternion, p=2, dim=1)**2

def get_rotation_matrix_from_quaternion(Q:torch.Tensor) -> torch.Tensor:
    """
    Returns a rotation matrix from a quaternion.

    Args:
        Q (torch.Tensor): Quaternion of shape (Nbatch,N,4)
    Returns:
        torch.Tensor: Rotation matrix of shape (Nbatch,N,3,3)
    """

    R = torch.zeros((Q.shape[0],Q.shape[1],3,3), dtype=Q.dtype, device=Q.device)

    R[...,0,0] = 2*(Q[...,0]**2 + Q[...,1]**2) - 1
    R[...,0,1] = 2*(Q[...,1]*Q[...,2] - Q[...,0]*Q[...,3])
    R[...,0,2] = 2*(Q[...,1]*Q[...,3] + Q[...,0]*Q[...,2])
    R[...,1,0] = 2*(Q[...,1]*Q[...,2] + Q[...,0]*Q[...,3])
    R[...,1,1] = 2*(Q[...,0]**2 + Q[...,2]**2) - 1
    R[...,1,2] = 2*(Q[...,2]*Q[...,3] - Q[...,0]*Q[...,1])
    R[...,2,0] = 2*(Q[...,1]*Q[...,3] - Q[...,0]*Q[...,2])
    R[...,2,1] = 2*(Q[...,2]*Q[...,3] + Q[...,0]*Q[...,1])
    R[...,2,2] = 2*(Q[...,0]**2 + Q[...,3]**2) - 1

    return R    

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

def gram_schmidt_mapping(x: torch.Tensor) -> torch.Tensor:
    """Gram Schmidt mapping
    
    Args:
        x (torch.Tensor): input tensor of shape (Nbatch, N, 4)
        
    Returns:
        torch.Tensor: output tensor of shape (Nbatch, N, 3, 3)
    """

    B = get_rotation_matrix_from_quaternion(x)
    B = B[..., :3]

    b1 = torch.nn.functional.normalize(B[..., 0], p=2, dim=-1)
    b2 = torch.nn.functional.normalize(B[..., 1] - torch.einsum('ij,ijk->ijk', torch.einsum('ijk,ijk->ij',b1,B[..., 1]),b1), p=2, dim=-1)
    b3 = torch.linalg.cross(b1, b2)

    return torch.stack([b1, b2, b3], dim=2).mT.squeeze(-1)

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