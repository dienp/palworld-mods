#include <cstdint>
#include <cstring>
#include <optional>

#include <DynamicOutput/Output.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/Property/FBoolProperty.hpp>
#include <Unreal/Property/FEnumProperty.hpp>
#include <Unreal/Property/FNumericProperty.hpp>
#include <Unreal/Property/FStructProperty.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/UEnum.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>

namespace {

using RC::LogLevel;
using RC::Output;
using RC::Unreal::FBoolProperty;
using RC::Unreal::FEnumProperty;
using RC::Unreal::FNumericProperty;
using RC::Unreal::FProperty;
using RC::Unreal::FStructProperty;
using RC::Unreal::UEnum;
using RC::Unreal::UFunction;
using RC::Unreal::UObject;
using RC::Unreal::UObjectGlobals;
using RC::Unreal::UnrealScriptFunctionCallableContext;

UFunction* g_indicator_info_function{};
UFunction* g_trigger_function{};
std::int32_t g_indicator_hook_id{};
std::int32_t g_trigger_hook_id{};
std::int64_t g_common_interact04{};
std::int64_t g_interact2{};
bool g_patched_once{};
bool g_conflict_logged{};
bool g_correlation_failure_logged{};

[[nodiscard]] bool is_supported_fishing_salvage_target(const UObject* object)
{
    if (!object) {
        return false;
    }

    const auto name = object->GetFullName();
    return name.find(
               STR("BP_MapObject_TreasureBox_FishingJunkSpot_Junk_Rank1_C"))
            != RC::StringType::npos
        || name.find(
               STR("BP_MapObject_TreasureBox_FishingJunkSpot_Junk_Rank2_C"))
            != RC::StringType::npos;
}

[[nodiscard]] void* value_pointer(
    FProperty* property,
    void* container)
{
    return property && container
        ? property->ContainerPtrToValuePtr<void>(container)
        : nullptr;
}

[[nodiscard]] std::optional<std::int64_t> resolve_enum_value(
    const RC::StringType& enum_path,
    const RC::StringType& value_name)
{
    auto* enum_object = UObjectGlobals::StaticFindObject<UEnum*>(
        nullptr,
        nullptr,
        enum_path);
    if (!enum_object) {
        return std::nullopt;
    }

    for (const auto& entry : enum_object->GetEnumNames()) {
        const auto name = entry.Key.ToString();
        if (name == value_name
            || name.ends_with(STR("::") + value_name)) {
            return entry.Value;
        }
    }
    return std::nullopt;
}

[[nodiscard]] bool write_integer_property(
    RC::Unreal::UStruct* owner,
    void* container,
    const RC::StringType& name,
    const std::int64_t value)
{
    auto* property = owner ? owner->GetPropertyByNameInChain(name) : nullptr;
    auto* target = value_pointer(property, container);
    if (!property || !target) {
        return false;
    }

    if (auto* enum_property = RC::Unreal::CastProperty<FEnumProperty>(property)) {
        auto* underlying = enum_property->GetUnderlyingProperty();
        if (!underlying) {
            return false;
        }
        underlying->SetIntPropertyValue(target, value);
        return true;
    }
    if (auto* numeric_property =
            RC::Unreal::CastProperty<FNumericProperty>(property)) {
        numeric_property->SetIntPropertyValue(target, value);
        return true;
    }
    return false;
}

[[nodiscard]] std::optional<std::int64_t> read_integer_property(
    FProperty* property,
    void* container)
{
    auto* target = value_pointer(property, container);
    if (!property || !target) {
        return std::nullopt;
    }

    if (auto* enum_property = RC::Unreal::CastProperty<FEnumProperty>(property)) {
        auto* underlying = enum_property->GetUnderlyingProperty();
        return underlying
            ? std::optional<std::int64_t>(
                  underlying->GetSignedIntPropertyValue(target))
            : std::nullopt;
    }
    if (auto* numeric_property =
            RC::Unreal::CastProperty<FNumericProperty>(property)) {
        return numeric_property->GetSignedIntPropertyValue(target);
    }
    return std::nullopt;
}

[[nodiscard]] bool write_bool_property(
    RC::Unreal::UStruct* owner,
    void* container,
    const RC::StringType& name,
    const bool value)
{
    auto* property = owner ? owner->GetPropertyByNameInChain(name) : nullptr;
    auto* bool_property = property
        ? RC::Unreal::CastProperty<FBoolProperty>(property)
        : nullptr;
    auto* target = value_pointer(property, container);
    if (!bool_property || !target) {
        return false;
    }
    bool_property->SetPropertyValue(target, value);
    return true;
}

[[nodiscard]] std::optional<bool> read_bool_property(
    RC::Unreal::UStruct* owner,
    void* container,
    const RC::StringType& name)
{
    auto* property = owner ? owner->GetPropertyByNameInChain(name) : nullptr;
    auto* bool_property = property
        ? RC::Unreal::CastProperty<FBoolProperty>(property)
        : nullptr;
    auto* target = value_pointer(property, container);
    return bool_property && target
        ? std::optional<bool>(bool_property->GetPropertyValue(target))
        : std::nullopt;
}

[[nodiscard]] UObject* get_target_interactive_object(UObject* interact_component)
{
    auto* target_property = interact_component
        ? interact_component->GetPropertyByNameInChain(
              STR("TargetInteractiveObject"))
        : nullptr;
    auto* target_interface = value_pointer(target_property, interact_component);

    // TScriptInterface stores the UObject pointer followed by its interface
    // pointer. Do not read it unless reflection confirms room for both.
    if (!target_property || !target_interface
        || target_property->GetElementSize()
            < static_cast<std::int32_t>(sizeof(void*) * 2)) {
        return nullptr;
    }
    return *static_cast<UObject**>(target_interface);
}

void patch_indicator_info(
    UnrealScriptFunctionCallableContext& context,
    void*)
{
    auto* component = context.Context;
    if (!is_supported_fishing_salvage_target(component)) {
        return;
    }

    auto* function = context.TheStack.Node();
    auto* locals = context.TheStack.Locals();
    auto* action_info_property = function
        ? function->GetPropertyByNameInChain(STR("ActionInfo"))
        : nullptr;
    auto* action_info_struct = action_info_property
        ? RC::Unreal::CastProperty<FStructProperty>(action_info_property)
        : nullptr;
    auto* action_info = value_pointer(action_info_property, locals);
    auto* action_info_type = action_info_struct
        ? action_info_struct->GetStruct()
        : nullptr;

    auto* interact1_property = action_info_type
        ? action_info_type->GetPropertyByNameInChain(STR("Interact1_Indicator"))
        : nullptr;
    auto* interact2_property = action_info_type
        ? action_info_type->GetPropertyByNameInChain(STR("Interact2_Indicator"))
        : nullptr;
    auto* interact2_struct = interact2_property
        ? RC::Unreal::CastProperty<FStructProperty>(interact2_property)
        : nullptr;
    auto* interact1 = value_pointer(interact1_property, action_info);
    auto* interact2 = value_pointer(interact2_property, action_info);

    if (!interact1_property || !interact2_property || !interact2_struct
        || !interact1 || !interact2
        || interact1_property->GetElementSize() != interact2_property->GetElementSize()) {
        Output::send<LogLevel::Error>(
            STR("[DeepSalvageNativeProof] event=indicator_patch_failed reason=layout\n"));
        return;
    }

    auto* action_data_type = interact2_struct->GetStruct();
    const auto existing_valid = read_bool_property(
        action_data_type,
        interact2,
        STR("bValid"));
    if (!existing_valid.has_value()) {
        Output::send<LogLevel::Error>(
            STR("[DeepSalvageNativeProof] event=indicator_patch_failed reason=valid_type\n"));
        return;
    }
    if (*existing_valid) {
        if (!g_conflict_logged) {
            g_conflict_logged = true;
            Output::send<LogLevel::Warning>(
                STR("[DeepSalvageNativeProof] event=indicator_conflict action=Interact2 target={}\n"),
                component->GetFullName());
        }
        return;
    }

    std::memcpy(
        interact2,
        interact1,
        static_cast<std::size_t>(interact2_property->GetElementSize()));

    const bool indicator_ok = write_integer_property(
        action_data_type,
        interact2,
        STR("IndicatorType"),
        g_common_interact04);
    const bool valid_ok = write_bool_property(
        action_data_type,
        interact2,
        STR("bValid"),
        true);

    if (!indicator_ok || !valid_ok) {
        Output::send<LogLevel::Error>(
            STR("[DeepSalvageNativeProof] event=indicator_patch_failed reason=field\n"));
        return;
    }

    if (!g_patched_once) {
        g_patched_once = true;
        Output::send<LogLevel::Normal>(
            STR("[DeepSalvageNativeProof] event=indicator_patch_ok action=Interact2 indicator=CommonInteract04 target={}\n"),
            component->GetFullName());
    }
}

void observe_trigger(
    UnrealScriptFunctionCallableContext& context,
    void*)
{
    auto* function = context.TheStack.Node();
    auto* locals = context.TheStack.Locals();
    auto* action_property = function
        ? function->GetPropertyByNameInChain(STR("ActionType"))
        : nullptr;
    const auto action = read_integer_property(action_property, locals);
    if (!action.has_value() || *action != g_interact2) {
        return;
    }

    auto* target = get_target_interactive_object(context.Context);
    if (!is_supported_fishing_salvage_target(target)) {
        if (!g_correlation_failure_logged) {
            g_correlation_failure_logged = true;
            Output::send<LogLevel::Warning>(
                STR("[DeepSalvageNativeProof] event=interact2_ignored reason=target_mismatch target={}\n"),
                target ? target->GetFullName() : STR("<null>"));
        }
        return;
    }

    Output::send<LogLevel::Normal>(
        STR("[DeepSalvageNativeProof] event=interact2_callback_ok target={}\n"),
        target->GetFullName());
}

class DeepSalvageNativeProof final : public RC::CppUserModBase {
public:
    DeepSalvageNativeProof()
    {
        ModName = STR("DeepSalvageNativeProof");
        ModVersion = STR("0.1.0");
        ModDescription = STR("Minimal native Interact2 proof for Deep Salvage.");
        ModAuthors = STR("ptd");
    }

    ~DeepSalvageNativeProof() override
    {
        if (g_indicator_info_function && g_indicator_hook_id != 0) {
            g_indicator_info_function->UnregisterHook(g_indicator_hook_id);
        }
        if (g_trigger_function && g_trigger_hook_id != 0) {
            g_trigger_function->UnregisterHook(g_trigger_hook_id);
        }
    }

    auto on_unreal_init() -> void override
    {
        g_indicator_info_function = UObjectGlobals::StaticFindObject<UFunction*>(
            nullptr,
            nullptr,
            STR("/Script/Pal.PalInteractiveObjectComponentInterface:GetIndicatorInfo"));
        g_trigger_function = UObjectGlobals::StaticFindObject<UFunction*>(
            nullptr,
            nullptr,
            STR("/Script/Pal.PalInteractComponent:StartTriggerInteract"));
        const auto interact2 = resolve_enum_value(
            STR("/Script/Pal.EPalInteractiveObjectActionType"),
            STR("Interact2"));
        const auto common_interact04 = resolve_enum_value(
            STR("/Script/Pal.EPalInteractiveObjectIndicatorType"),
            STR("CommonInteract04"));

        if (!g_indicator_info_function || !g_trigger_function
            || !interact2.has_value() || !common_interact04.has_value()) {
            Output::send<LogLevel::Error>(
                STR("[DeepSalvageNativeProof] event=init_failed reason=missing_reflection indicator={} trigger={} interact2={} common_interact04={}\n"),
                g_indicator_info_function != nullptr,
                g_trigger_function != nullptr,
                interact2.has_value(),
                common_interact04.has_value());
            return;
        }
        g_interact2 = *interact2;
        g_common_interact04 = *common_interact04;

        g_indicator_hook_id =
            g_indicator_info_function->RegisterPostHook(patch_indicator_info, nullptr);
        g_trigger_hook_id =
            g_trigger_function->RegisterPreHook(observe_trigger, nullptr);

        Output::send<LogLevel::Normal>(
            STR("[DeepSalvageNativeProof] event=init_ok indicator_hook={} trigger_hook={}\n"),
            g_indicator_hook_id,
            g_trigger_hook_id);
    }
};

} // namespace

#define DEEP_SALVAGE_NATIVE_PROOF_API __declspec(dllexport)

extern "C" {

DEEP_SALVAGE_NATIVE_PROOF_API RC::CppUserModBase* start_mod()
{
    return new DeepSalvageNativeProof();
}

DEEP_SALVAGE_NATIVE_PROOF_API void uninstall_mod(RC::CppUserModBase* mod)
{
    delete mod;
}

}
