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

#include <benchmarks/common/generate_input.hpp>
#include <benchmarks/common/memory_statistics.hpp>

#include <cudf/groupby.hpp>

#include <nvbench/nvbench.cuh>

#include <optional>

template <typename Type>
void bench_groupby_max(nvbench::state& state, nvbench::type_list<Type>)
{
  auto const size = static_cast<cudf::size_type>(state.get_int64("num_rows"));

  auto const keys = [&] {
    data_profile const profile = data_profile_builder().cardinality(0).no_validity().distribution(
      cudf::type_to_id<int32_t>(), distribution_id::UNIFORM, 0, 100);
    return create_random_column(cudf::type_to_id<int32_t>(), row_count{size}, profile);
  }();

  auto const null_freq = state.get_float64("null_probability");
  bool const has_null  = null_freq > 0;

  auto const vals = [&] {
    auto builder = data_profile_builder()
                     .cardinality(0)
                     .null_probability(has_null ? std::optional<double>(null_freq) : std::nullopt)
                     .distribution(cudf::type_to_id<Type>(), distribution_id::UNIFORM, 0, 1000);

    return create_random_column(cudf::type_to_id<Type>(), row_count{size}, data_profile{builder});
  }();

  auto const keys_view  = keys->view();
  auto const keys_table = cudf::table_view({keys_view, keys_view, keys_view});
  auto gb_obj           = cudf::groupby::groupby(keys_table);

  std::vector<cudf::groupby::aggregation_request> requests;
  requests.emplace_back(cudf::groupby::aggregation_request());
  requests[0].values = vals->view();
  requests[0].aggregations.push_back(cudf::make_max_aggregation<cudf::groupby_aggregation>());

  // Add memory statistics
  state.add_global_memory_reads<nvbench::uint8_t>(required_bytes(vals->view()));
  state.add_global_memory_reads<nvbench::uint8_t>(required_bytes(keys_table));

  // The number of written bytes depends on random distribution of keys.
  // For larger sizes it converges against the number of unique elements
  // in the input distribution (101 elements)
  auto [res_table, res_agg] = gb_obj.aggregate(requests);
  state.add_global_memory_writes<uint8_t>(required_bytes(res_table->view()));
  state.add_global_memory_writes<uint8_t>(required_bytes(res_agg));

  state.set_cuda_stream(nvbench::make_cuda_stream_view(cudf::get_default_stream().value()));
  state.exec(nvbench::exec_tag::sync,
             [&](nvbench::launch& launch) { auto const result = gb_obj.aggregate(requests); });
}

NVBENCH_BENCH_TYPES(bench_groupby_max,
                    NVBENCH_TYPE_AXES(nvbench::type_list<int32_t, int64_t, float, double>))
  .set_name("groupby_max")
  .add_int64_power_of_two_axis("num_rows", {12, 18, 24})
  .add_float64_axis("null_probability", {0, 0.1, 0.9});
