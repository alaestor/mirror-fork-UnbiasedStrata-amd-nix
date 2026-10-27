#include "sampling_defaults.hpp"

#include <cstdio>

using namespace strata_frontend;
using json = common_json;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #cond); ++failures; } } while (0)

int main() {
    common_params_sampling s;
    const auto flash = sampling_defaults("qwen4exp", true, s, false);
    CHECK(flash.at("temperature").get<float>() == 1.0f);
    CHECK(flash.at("top_p").get<float>() == 0.95f);
    CHECK(flash.at("top_k").get<int>() == 20);
    CHECK(flash.at("min_p").get<float>() == 0.0f);
    CHECK(flash.at("presence_penalty").get<float>() == 0.0f);
    CHECK(flash.at("repeat_penalty").get<float>() == 1.0f);
    CHECK(sampling_defaults("qwen35moe", true, s, false).at("presence_penalty").get<float>() == 1.5f);
    for (const char * arch : {"qwen4exp", "qwen35moe"}) {
        const auto instruct = sampling_defaults(arch, false, s, false);
        CHECK(instruct.at("temperature").get<float>() == 0.7f);
        CHECK(instruct.at("top_p").get<float>() == 0.8f);
        CHECK(instruct.at("presence_penalty").get<float>() == 1.5f);
    }
    CHECK(sampling_defaults("unknown", true, s, false).empty());
    CHECK(sampling_defaults("", false, s, false).empty());

    // Explicit server values equal to generic defaults and zero are still overrides.
    s.user_sampling_config = COMMON_PARAMS_SAMPLING_CONFIG_TEMP | COMMON_PARAMS_SAMPLING_CONFIG_TOP_K
                          | COMMON_PARAMS_SAMPLING_CONFIG_MIN_P | COMMON_PARAMS_SAMPLING_CONFIG_TOP_P
                          | COMMON_PARAMS_SAMPLING_CONFIG_PENALTY_REPEAT;
    s.temp = 0; s.top_k = 40; s.top_p = 0.9f; s.min_p = 0.05f; s.penalty_repeat = 1.1f;
    s.penalty_present = 0;
    auto configured = sampling_defaults("qwen35moe", true, s, true);
    CHECK(configured.at("temperature").get<float>() == 0);
    CHECK(configured.at("top_k").get<int>() == 40);
    CHECK(configured.at("top_p").get<float>() == 0.9f);
    CHECK(configured.at("min_p").get<float>() == 0.05f);
    CHECK(configured.at("repeat_penalty").get<float>() == 1.1f);
    CHECK(configured.at("presence_penalty").get<float>() == 0);
    json request = {{"temperature", 0.6}, {"top_k", 0}, {"min_p", 0}, {"presence_penalty", 0}};
    fill_sampling_defaults(request, configured);
    CHECK(request.at("temperature").get<float>() == 0.6f);
    CHECK(request.at("top_k").get<int>() == 0);
    CHECK(request.at("min_p").get<float>() == 0);
    CHECK(request.at("presence_penalty").get<float>() == 0);
    json greedy = {{"temperature", 0}};
    fill_sampling_defaults(greedy, flash);
    CHECK(greedy.at("temperature").get<float>() == 0);
    json unspecified = {{"temperature", nullptr}, {"top_k", nullptr}};
    fill_sampling_defaults(unspecified, flash);
    CHECK(unspecified.at("temperature").get<float>() == 1);
    CHECK(unspecified.at("top_k").get<int>() == 20);

    CHECK(sampling_thinking(json::object(), true, {}));
    CHECK(!sampling_thinking(json::object(), true, {{"enable_thinking", "false"}}));
    CHECK(sampling_thinking({{"chat_template_kwargs", {{"enable_thinking", true}}}}, false,
                            {{"enable_thinking", "false"}}));
    CHECK(!sampling_thinking({{"chat_template_kwargs", {{"enable_thinking", false}}}}, true, {}));
    CHECK(!sampling_thinking({{"reasoning_effort", "none"},
                              {"chat_template_kwargs", {{"enable_thinking", true}}}}, true, {}));
    CHECK(!sampling_thinking({{"reasoning_effort", "high"}}, false, {}));
    return failures ? 1 : 0;
}
