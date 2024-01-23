/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/strings/udf/udf_apis.hpp>
#include <cudf/strings/udf/udf_string.cuh>

#include <cudf/column/column_factories.hpp>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/utilities/default_stream.hpp>

#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform.h>

#include <numba_cuda_runtime.cuh>

namespace cudf {
namespace strings {
namespace udf {
namespace detail {
namespace {

/**
 * @brief Functor wraps string_view objects around udf_string objects
 *
 * No string data is copied.
 */
struct udf_string_to_string_view_transform_fn {
  __device__ cudf::string_view operator()(cudf::strings::udf::udf_string const& dstr)
  {
    return dstr.data() == nullptr ? cudf::string_view{}
                                  : cudf::string_view{dstr.data(), dstr.size_bytes()};
  }
};

struct managed_udf_string_to_string_view_transform_fn {
  __device__ cudf::string_view operator()(
    cudf::strings::udf::managed_udf_string const& managed_dstr)
  {
    return managed_dstr.udf_str.data() == nullptr
             ? cudf::string_view{}
             : cudf::string_view{managed_dstr.udf_str.data(), managed_dstr.udf_str.size_bytes()};
  }
};

}  // namespace

/**
 * @copydoc to_string_view_array
 *
 * @param stream CUDA stream used for allocating/copying device memory and launching kernels
 */
std::unique_ptr<rmm::device_buffer> to_string_view_array(cudf::column_view const input,
                                                         rmm::cuda_stream_view stream)
{
  return std::make_unique<rmm::device_buffer>(
    std::move(cudf::strings::detail::create_string_vector_from_column(
                cudf::strings_column_view(input), stream, rmm::mr::get_current_device_resource())
                .release()));
}

/**
 * @copydoc column_from_udf_string_array
 *
 * @param stream CUDA stream used for allocating/copying device memory and launching kernels
 */
std::unique_ptr<cudf::column> column_from_udf_string_array(udf_string* d_strings,
                                                           cudf::size_type size,
                                                           rmm::cuda_stream_view stream)
{
  // create string_views of the udf_strings
  auto indices = rmm::device_uvector<cudf::string_view>(size, stream);
  thrust::transform(rmm::exec_policy(stream),
                    d_strings,
                    d_strings + size,
                    indices.data(),
                    udf_string_to_string_view_transform_fn{});

  return cudf::make_strings_column(indices, cudf::string_view(nullptr, 0), stream);
}

/**
 * @copydoc column_from_managed_udf_string_array
 *
 * @param stream CUDA stream used for allocating/copying device memory and launching kernels
 */
std::unique_ptr<cudf::column> column_from_managed_udf_string_array(
  managed_udf_string* managed_strings, cudf::size_type size, rmm::cuda_stream_view stream)
{
  // create string_views of the udf_strings
  auto indices = rmm::device_uvector<cudf::string_view>(size, stream);
  thrust::transform(rmm::exec_policy(stream),
                    managed_strings,
                    managed_strings + size,
                    indices.data(),
                    managed_udf_string_to_string_view_transform_fn{});

  auto result = cudf::make_strings_column(indices, cudf::string_view(nullptr, 0), stream);
  stream.synchronize();
  return result;
}

/**
 * @copydoc free_udf_string_array
 *
 * @param stream CUDA stream used for allocating/copying device memory and launching kernels
 */
void free_udf_string_array(cudf::strings::udf::udf_string* d_strings,
                           cudf::size_type size,
                           rmm::cuda_stream_view stream)
{
  thrust::for_each_n(rmm::exec_policy(stream),
                     thrust::make_counting_iterator(0),
                     size,
                     [d_strings] __device__(auto idx) { d_strings[idx].clear(); });
}

/**
 * @copydoc free_managed_udf_string_array
 *
 * @param stream CUDA stream used for allocating/copying device memory and launching kernels
 */
void free_managed_udf_string_array(cudf::strings::udf::managed_udf_string* managed_strings,
                                   cudf::size_type size,
                                   rmm::cuda_stream_view stream)
{
  thrust::for_each_n(rmm::exec_policy(stream),
                     thrust::make_counting_iterator(0),
                     size,
                     [managed_strings] __device__(auto idx) {
                       NRT_MemInfo* mi = reinterpret_cast<NRT_MemInfo*>(managed_strings[idx].meminfo);

                       // Function pointer was compiled in another module
                       // so can't call it directly, need to replace it with one
                       // that was compiled along with this code
                       mi->dtor = udf_str_dtor;

                       NRT_internal_decref(mi);
                     });
}

}  // namespace detail

// external APIs

std::unique_ptr<rmm::device_buffer> to_string_view_array(cudf::column_view const input)
{
  return detail::to_string_view_array(input, cudf::get_default_stream());
}

std::unique_ptr<cudf::column> column_from_udf_string_array(udf_string* d_strings,
                                                           cudf::size_type size)
{
  return detail::column_from_udf_string_array(d_strings, size, cudf::get_default_stream());
}

std::unique_ptr<cudf::column> column_from_managed_udf_string_array(
  managed_udf_string* managed_strings, cudf::size_type size)
{
  return detail::column_from_managed_udf_string_array(
    managed_strings, size, cudf::get_default_stream());
}

void free_udf_string_array(udf_string* d_strings, cudf::size_type size)
{
  detail::free_udf_string_array(d_strings, size, cudf::get_default_stream());
}

void free_managed_udf_string_array(managed_udf_string* managed_strings, cudf::size_type size)
{
  detail::free_managed_udf_string_array(managed_strings, size, cudf::get_default_stream());
}

}  // namespace udf
}  // namespace strings
}  // namespace cudf