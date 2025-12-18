fn Range(comptime ElementType: type) type {
    return struct {
        const This = @This();

        start: ElementType,
        end: ElementType,

        pub fn init(start: ElementType, end: ElementType) This {
            return .{
                .start = start,
                .end = end,
            };
        }
    };
}

pub fn BoundBox(comptime ElementType: type) type {
    return struct {
        x: Range(ElementType),
        y: Range(ElementType),
        z: Range(ElementType),
    };
}
