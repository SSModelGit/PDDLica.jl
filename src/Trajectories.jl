"Return recorded variable names, optionally filtered by component or signal kind."
function available_variables(result::SimulationResult; component=nothing, kind=nothing,
                             numeric_only=false)
    names = String[]
    for (name, series) in result.trajectories
        !isnothing(component) && !startswith(name, String(component) * ".") && continue
        !isnothing(kind) && series.kind != Symbol(kind) && continue
        if numeric_only
            any(v -> v isa Number || v isa Bool, series.values) || continue
        end
        push!(names, name)
    end
    sort!(names)
end

trajectory(result::SimulationResult, component::AbstractString, variable::AbstractString) =
    trajectory(result, String(component) * "." * String(variable))

"Return one recorded trajectory, including duplicate pre/post-event timestamps."
function trajectory(result::SimulationResult, name::AbstractString)
    haskey(result.trajectories, name) || throw(ArgumentError(
        "trajectory '$name' was not recorded; call available_variables(result) to list names"))
    result.trajectories[String(name)]
end

function _numeric_trajectory(series::VariableTrajectory)
    isempty(series.values) && throw(ArgumentError("trajectory '$(series.name)' is empty"))
    all(v -> v isa Number || v isa Bool, series.values) || throw(ArgumentError(
        "trajectory '$(series.name)' is not numeric and cannot be drawn as a line"))
    series.times, Float64[Float64(v) for v in series.values]
end

"Draw one variable directly in a terminal-backed Julia REPL."
function plot_trajectory(result::SimulationResult, name::AbstractString;
                         width=80, height=20, title=String(name), xlabel="time", kwargs...)
    series = trajectory(result, name)
    times, values = _numeric_trajectory(series)
    if all(v -> v isa Bool, series.values)
        UnicodePlots.stairs(times, values; style=:post, name=String(name),
            title=title, xlabel=xlabel, width=width, height=height, kwargs...)
    else
        UnicodePlots.lineplot(times, values; name=String(name), title=title,
            xlabel=xlabel, width=width, height=height, kwargs...)
    end
end


plot_trajectory(result::SimulationResult, component::AbstractString,
                variable::AbstractString; kwargs...) =
    plot_trajectory(result, String(component) * "." * String(variable); kwargs...)

"Overlay several numeric trajectories in one terminal plot."
function plot_trajectories(result::SimulationResult, names;
                           width=80, height=20, title="PDDLica simulation",
                           xlabel="time", kwargs...)
    requested = String[string(name) for name in names]
    isempty(requested) && throw(ArgumentError("at least one variable name is required"))
    data = [_numeric_trajectory(trajectory(result, name)) for name in requested]
    all_values = reduce(vcat, last.(data))
    limits = extrema(all_values)
    if limits[1] == limits[2]
        padding = iszero(limits[1]) ? 1.0 : abs(limits[1]) * 0.05
        limits = (limits[1] - padding, limits[2] + padding)
    end
    times, values = data[1]
    plot = haskey(kwargs, :ylim) ?
        UnicodePlots.lineplot(times, values; name=requested[1], title=title,
            xlabel=xlabel, width=width, height=height, kwargs...) :
        UnicodePlots.lineplot(times, values; name=requested[1], title=title,
            xlabel=xlabel, ylim=limits, width=width, height=height, kwargs...)
    for (name, (times, values)) in zip(requested[2:end], data[2:end])
        UnicodePlots.lineplot!(plot, times, values; name=name)
    end
    plot
end
