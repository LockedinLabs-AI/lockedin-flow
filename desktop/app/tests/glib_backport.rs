// This is an optimized Linux regression for RUSTSEC-2024-0429, not a mock.
#[cfg(target_os = "linux")]
#[test]
fn variant_string_iteration_uses_a_valid_mutable_out_pointer() {
    use glib::variant::ToVariant;
    for values in [vec![], vec!["synthetic"], vec!["alpha", "José", "final"]] {
        let variant = values.to_variant();
        assert_eq!(
            variant.array_iter_str().unwrap().collect::<Vec<_>>(),
            values
        );
        assert_eq!(
            variant.array_iter_str().unwrap().rev().collect::<Vec<_>>(),
            values.iter().rev().copied().collect::<Vec<_>>()
        );
    }
}
