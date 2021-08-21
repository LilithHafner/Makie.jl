using FreeTypeAbstraction: height_insensitive_boundingbox

"""
Calculates the exact boundingbox of a Scene/Plot, without considering any transformation
"""
raw_boundingbox(x::Atomic) = data_limits(x)


rootparent(x) = rootparent(parent(x))
rootparent(x::Scene) = x

# function raw_boundingbox(x::Annotations)
#     bb = raw_boundingbox(x.plots)
#     inv(modelmatrix(rootparent(x))) * bb
# end

raw_boundingbox(x::Combined) = raw_boundingbox(x.plots)
boundingbox(x) = raw_boundingbox(x)

function combined_modelmatrix(x)
    m = Mat4f0(I)
    while true
        m = modelmatrix(x) * m
        if parent(x) !== nothing && parent(x) isa Combined
            x = parent(x)
        else
            break
        end
    end
    return m
end

function modelmatrix(x)
    t = transformation(x)
    transformationmatrix(t.translation[], t.scale[], t.rotation[])
end

function boundingbox(x::Atomic)
    bb = raw_boundingbox(x)
    return combined_modelmatrix(x) * bb
end

boundingbox(scene::Scene) = raw_boundingbox(scene)
function raw_boundingbox(scene::Scene)
    @warn("BB FROM SCENE")
    if scene[OldAxis] !== nothing
        return raw_boundingbox(scene[OldAxis])
    elseif camera_controls(scene) == EmptyCamera()
        # Empty camera means this is a parent scene that itself doesn't display anything
        return raw_boundingbox(scene.children)
    else
        plots = plots_from_camera(scene)
        children = filter(scene.children) do child
            child.camera == scene.camera
        end
        return raw_boundingbox([plots; children])
    end
end

function raw_boundingbox(plots::Vector)
    isempty(plots) && return FRect3D()
    plot_idx = iterate(plots)
    bb = FRect3D()
    while plot_idx !== nothing
        plot, idx = plot_idx
        plot_idx = iterate(plots, idx)
        # isvisible(plot) || continue
        bb2 = boundingbox(plot)
        isfinite_rect(bb) || (bb = bb2)
        isfinite_rect(bb2) || continue
        bb = union(bb, bb2)
    end
    return bb
end

function project_widths(matrix, vec)
    pr = project(matrix, vec)
    zero = project(matrix, zeros(typeof(vec)))
    return pr - zero
end

function rotate_bbox(bb::FRect3D, rot)
    points = decompose(Point3f0, bb)
    FRect3D(Ref(rot) .* points)
end

function gl_bboxes(gl::GlyphCollection)
    scales = gl.scales.sv isa Vec2f0 ? (gl.scales.sv for _ in gl.extents) : gl.scales.sv
    map(gl.extents, gl.fonts, scales) do ext, font, scale
        unscaled_hi_bb = height_insensitive_boundingbox(ext, font)
        hi_bb = FRect2D(
            Makie.origin(unscaled_hi_bb) * scale,
            widths(unscaled_hi_bb) * scale
        )
    end
end

function boundingbox(glyphcollection::GlyphCollection, position::Point3f0, rotation::Quaternion)

    if isempty(glyphcollection.glyphs)
        return FRect3D(position, Vec3f0(0, 0, 0))
    end

    chars = glyphcollection.glyphs
    glyphorigins = glyphcollection.origins
    glyphbbs = gl_bboxes(glyphcollection)

    bb = FRect3D()
    for (char, charo, glyphbb) in zip(chars, glyphorigins, glyphbbs)
        # ignore line breaks
        # char in ('\r', '\n') && continue

        charbb = rotate_bbox(FRect3D(glyphbb), rotation) + charo + position
        if !isfinite_rect(bb)
            bb = charbb
        else
            bb = union(bb, charbb)
        end
    end
    !isfinite_rect(bb) && error("Invalid text boundingbox")
    bb
end

function boundingbox(layouts::AbstractArray{<:GlyphCollection}, positions, rotations)

    if isempty(layouts)
        FRect3D((0, 0, 0), (0, 0, 0))
    else
        bb = FRect3D()
        broadcast_foreach(layouts, positions, rotations) do layout, pos, rot
            if !isfinite_rect(bb)
                bb = boundingbox(layout, pos, rot)
            else
                bb = union(bb, boundingbox(layout, pos, rot))
            end
        end
        !isfinite_rect(bb) && error("Invalid text boundingbox")
        bb
    end
end

function boundingbox(x::Text{<:Tuple{<:GlyphCollection}})
    boundingbox(
        x[1][],
        to_ndim(Point3f0, x.position[], 0),
        to_rotation(x.rotation[])
    )
end

function boundingbox(x::Text{<:Tuple{<:AbstractArray{<:GlyphCollection}}})
    boundingbox(
        x[1][],
        to_ndim.(Point3f0, x.position[], 0),
        to_rotation(x.rotation[])
    )
end

function text_bb(str, font, size)
    rot = Quaternionf0(0,0,0,1)
    layout = layout_text(
        str, size, font, Vec2f0(0), rot, 0.5, 1.0,
        RGBAf0(0, 0, 0, 0), RGBAf0(0, 0, 0, 0), 0f0)
    return boundingbox(layout, Point3f0(0), rot)
end

"""
Calculate an approximation of a tight rectangle around a 2D rectangle rotated by `angle` radians.
This is not perfect but works well enough. Check an A vs X to see the difference.
"""
function rotatedrect(rect::Rect{2}, angle)
    ox, oy = rect.origin
    wx, wy = rect.widths
    points = @SMatrix([
        ox oy;
        ox oy+wy;
        ox+wx oy;
        ox+wx oy+wy;
    ])
    mrot = @SMatrix([
        cos(angle) -sin(angle);
        sin(angle) cos(angle);
    ])
    rotated = mrot * points'

    rmins = minimum(rotated, dims = 2)
    rmaxs = maximum(rotated, dims = 2)

    return Rect2D(rmins..., (rmaxs .- rmins)...)
end
