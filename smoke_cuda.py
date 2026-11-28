import torch
print("torch", torch.__version__)
print("cuda_available", torch.cuda.is_available())
if torch.cuda.is_available():
    print("device", torch.cuda.get_device_name(0))
    a = torch.randn(2000, 2000, device="cuda")
    b = a @ a
    torch.cuda.synchronize()
    print("matmul_sum", float(b.sum()))
    print("SMOKE_OK")
else:
    print("SMOKE_FAIL")
