/*
* SPDX-FileCopyrightText: Copyright (c) 2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
* SPDX-License-Identifier: Apache-2.0
Copyright (c) 2012, Anaconda, Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#ifndef _NRT_H
#define _NRT_H

#include <cuda/atomic>

typedef __device__ void (*NRT_dtor_function)(void* ptr, size_t size, void* info);
typedef __device__ void (*NRT_dealloc_func)(void* ptr, void* dealloc_info);

typedef struct MemInfo NRT_MemInfo;

extern "C" {
struct MemInfo {
  cuda::atomic<size_t, cuda::thread_scope_device> refct;
  NRT_dtor_function dtor;
  void* dtor_info;
  void* data;
  size_t size;
};
}

// Globally needed variables
struct NRT_MemSys {
  struct {
    bool enabled;
    cuda::atomic<size_t, cuda::thread_scope_device> alloc;
    cuda::atomic<size_t, cuda::thread_scope_device> free;
    cuda::atomic<size_t, cuda::thread_scope_device> mi_alloc;
    cuda::atomic<size_t, cuda::thread_scope_device> mi_free;
  } stats;
};

/* The Memory System object */
__device__ NRT_MemSys DefaultMSys = {.stats = {false, 0, 0, 0, 0}};
__device__ NRT_MemSys* TheMSys    = &DefaultMSys;

__global__ void setGlobalMSysKernel(NRT_MemSys* deviceMSys) { TheMSys = deviceMSys; }

extern "C" __device__ void* NRT_Allocate(size_t size)
{
  void* ptr = NULL;
  ptr       = malloc(size);
  if (TheMSys->stats.enabled) { TheMSys->stats.alloc++; }
  return ptr;
}

extern "C" __device__ void NRT_MemInfo_init(
  NRT_MemInfo* mi, void* data, size_t size, NRT_dtor_function dtor, void* dtor_info)
{
  mi->refct     = 1; /* starts with 1 refct */
  mi->dtor      = dtor;
  mi->dtor_info = dtor_info;
  mi->data      = data;
  mi->size      = size;
  if (TheMSys->stats.enabled) { TheMSys->stats.mi_alloc++; }
}

__device__ NRT_MemInfo* NRT_MemInfo_new(void* data,
                                        size_t size,
                                        NRT_dtor_function dtor,
                                        void* dtor_info)
{
  NRT_MemInfo* mi = (NRT_MemInfo*)NRT_Allocate(sizeof(NRT_MemInfo));
  if (mi != NULL) { NRT_MemInfo_init(mi, data, size, dtor, dtor_info); }
  return mi;
}

extern "C" __device__ void NRT_Free(void* ptr)
{
  free(ptr);
  if (TheMSys->stats.enabled) { TheMSys->stats.free++; }
}

extern "C" __device__ void NRT_dealloc(NRT_MemInfo* mi) { NRT_Free(mi); }

extern "C" __device__ void NRT_MemInfo_destroy(NRT_MemInfo* mi)
{
  NRT_dealloc(mi);
  if (TheMSys->stats.enabled) { TheMSys->stats.mi_free++; }
}
extern "C" __device__ void NRT_MemInfo_call_dtor(NRT_MemInfo* mi)
{
  if (mi->dtor) /* We have a destructor */
    mi->dtor(mi->data, mi->size, NULL);
  /* Clear and release MemInfo */
  NRT_MemInfo_destroy(mi);
}

/*
  c++ version of the NRT_decref function that usually is added to
  the final kernel link in PTX form by numba. This version may be
  used by c++ APIs that accept ownership of live objects and must
  manage them going forward.
*/
extern "C" __device__ void NRT_internal_decref(NRT_MemInfo* mi)
{
  mi->refct--;
  if (mi->refct == 0) { NRT_MemInfo_call_dtor(mi); }
}

#endif
