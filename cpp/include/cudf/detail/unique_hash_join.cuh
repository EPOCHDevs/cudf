/*
 * Copyright (c) 2024, NVIDIA CORPORATION.
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
#pragma once

#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/types.hpp>

#include <cuco/static_set.cuh>

namespace cudf::detail {

using cudf::experimental::row::lhs_index_type;
using cudf::experimental::row::rhs_index_type;

/**
 * @brief An comparator adapter wrapping both self comparator and two table comparator
 */
template <typename Equal>
struct comparator_adapter {
  comparator_adapter(Equal const& d_equal) : _d_equal{d_equal} {}

  __device__ constexpr auto operator()(
    cuco::pair<hash_value_type, lhs_index_type> const&,
    cuco::pair<hash_value_type, lhs_index_type> const&) const noexcept
  {
    // All build table keys are unique thus `false` no matter what
    return false;
  }

  __device__ constexpr auto operator()(
    cuco::pair<hash_value_type, lhs_index_type> const& lhs,
    cuco::pair<hash_value_type, rhs_index_type> const& rhs) const noexcept
  {
    if (lhs.first != rhs.first) { return false; }
    return _d_equal(lhs.second, rhs.second);
  }

 private:
  Equal _d_equal;
};

template <typename Hasher>
struct hasher_adapter {
  hasher_adapter(Hasher const& d_hasher = {}) : _d_hasher{d_hasher} {}

  template <typename T>
  __device__ constexpr auto operator()(cuco::pair<hash_value_type, T> const& key) const noexcept
  {
    return _d_hasher(key.first);
  }

 private:
  Hasher _d_hasher;
};

/**
 * @brief Unique hash join that builds hash table in creation and probes results in subsequent
 * `*_join` member functions.
 *
 * @tparam Hasher Unary callable type
 * @tparam HasNested Flag indicating whether there are nested columns in build/probe table
 */
template <typename Hasher, has_nested HasNested = has_nested::NO>
struct unique_hash_join {
 private:
  /// Row equality type for nested columns
  using nested_row_equal = cudf::experimental::row::equality::strong_index_comparator_adapter<
    cudf::experimental::row::equality::device_row_comparator<true, cudf::nullate::DYNAMIC>>;
  /// Row equality type for flat columns
  using flat_row_equal = cudf::experimental::row::equality::strong_index_comparator_adapter<
    cudf::experimental::row::equality::device_row_comparator<false, cudf::nullate::DYNAMIC>>;

  /// Device row equal type
  using d_equal_type =
    std::conditional_t<HasNested == has_nested::YES, nested_row_equal, flat_row_equal>;
  using first_hasher        = hasher_adapter<thrust::identity<hash_value_type>>;
  using second_hasher       = hasher_adapter<Hasher>;
  using probing_scheme_type = cuco::experimental::linear_probing<1, first_hasher>;
  using cuco_storge_type    = cuco::experimental::storage<1>;

  /// Hash table type
  using hash_table_type =
    cuco::experimental::static_set<cuco::pair<hash_value_type, lhs_index_type>,
                                   cuco::experimental::extent<std::size_t>,
                                   cuda::thread_scope_device,
                                   comparator_adapter<d_equal_type>,
                                   probing_scheme_type,
                                   cudf::detail::cuco_allocator,
                                   cuco_storge_type>;

  bool _is_empty;   ///< true if `_hash_table` is empty
  bool _has_nulls;  ///< true if nulls are present in either build table or probe table
  cudf::null_equality _nulls_equal;  ///< whether to consider nulls as equal
  cudf::table_view _build;           ///< input table to build the hash map
  cudf::table_view _probe;           ///< input table to probe the hash map
  std::shared_ptr<cudf::experimental::row::equality::preprocessed_table>
    _preprocessed_build;  ///< input table preprocssed for row operators
  std::shared_ptr<cudf::experimental::row::equality::preprocessed_table>
    _preprocessed_probe;        ///< input table preprocssed for row operators
  hash_table_type _hash_table;  ///< hash table built on `_build`

 public:
  unique_hash_join()                                   = delete;
  ~unique_hash_join()                                  = default;
  unique_hash_join(unique_hash_join const&)            = delete;
  unique_hash_join(unique_hash_join&&)                 = delete;
  unique_hash_join& operator=(unique_hash_join const&) = delete;
  unique_hash_join& operator=(unique_hash_join&&)      = delete;

  /// Row equality type for nested columns
  /**
   * @brief Constructor that internally builds the hash table based on the given `build` table.
   *
   * @throw cudf::logic_error if the number of columns in `build` table is 0.
   *
   * @param build The build table, from which the hash table is built
   * @param probe The probe table
   * @param has_nulls Flag to indicate if the there exists any nulls in the `build` table or
   *        any `probe` table that will be used later for join.
   * @param compare_nulls Controls whether null join-key values should match or not.
   * @param stream CUDA stream used for device memory operations and kernel launches.
   */
  unique_hash_join(cudf::table_view const& build,
                   cudf::table_view const& probe,
                   bool has_nulls,
                   cudf::null_equality compare_nulls,
                   rmm::cuda_stream_view stream);

  /**
   * @copydoc cudf::hash_join::inner_join
   */
  std::pair<std::unique_ptr<rmm::device_uvector<size_type>>,
            std::unique_ptr<rmm::device_uvector<size_type>>>
  inner_join(rmm::cuda_stream_view stream, rmm::mr::device_memory_resource* mr) const;
};
}  // namespace cudf::detail
