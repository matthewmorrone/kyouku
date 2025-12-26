# Token Action Panel Geometry Notes

The legacy diff experimented with measuring the host container height so the dictionary panel could set its detent limit without assuming `UIScreen.main.bounds`. Keeping the details here lets us revisit it later without merging the user-facing behavior change now.

## Core Idea

Wrap the panel in a `GeometryReader`, capture the available height, and base `panelHeightLimit` on that measurement:

```swift
@State private var containerHeight: CGFloat = 812

var body: some View {
    panelSurface
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerHeight = proxy.size.height }
                    .onChange(of: proxy.size.height, initial: false) { _, newValue in
                        containerHeight = newValue
                    }
            }
        )
}

private var panelHeightLimit: CGFloat {
    min(containerHeight * 0.55, 480)
}
```

This replaces the current `UIScreen.main.bounds.height` lookup so the panel adapts inside split-view or sheet contexts. When we decide to adopt it, we’ll need to:

1. Add the `containerHeight` state and geometry background to `TokenActionPanel`.
2. Update `panelHeightLimit` to use the new measurement.
3. Verify animations/safe-area handling still feel right on compact layouts.

For now, the idea lives here for safekeeping.
