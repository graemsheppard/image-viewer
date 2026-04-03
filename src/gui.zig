const std = @import("std");
const glfw = @cImport({
    @cInclude("glfw3.h");
});
const gl = @cImport({
    @cInclude("glad/glad.h");
});
const bmp = @import("bitmap.zig");
const print = std.debug.print;
pub const Window = glfw.GLFWwindow;

/// Initialize our window with the correct size
pub fn createWindow(_: std.mem.Allocator, bitmap: bmp.Bitmap) GLError!void {
    if (glfw.glfwInit() == 0) {
        return GLError.GLFWInitializationError;
    }
    defer glfw.glfwTerminate();
    
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, glfw.GL_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GL_TRUE);

    const window = glfw.glfwCreateWindow(256, 256, @ptrCast(bitmap.file_name), null, null);
    
    if (window == null) {
        return GLError.WindowCreationError;
    }

    defer glfw.glfwDestroyWindow(window);
    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1);

    if (gl.gladLoadGLLoader(@ptrCast(&glfw.glfwGetProcAddress)) == 0) {
        return GLError.GLInitializationError;
    }

    // Setup the texture with the pixel data
    var texture_id = createTexture();
    defer gl.glDeleteTextures(1, &texture_id);
    
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture_id);

    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_BORDER);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_BORDER);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    const dimensions = bitmap.dib_header.getDimensions();
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGB,
        dimensions.x,
        dimensions.y,
        0,
        gl.GL_BGR,
        gl.GL_UNSIGNED_BYTE,
        @ptrCast(bitmap.pixels)
    );

    // Initialize vertex array, required before OpenGL can draw
    var vao: u32 = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    defer gl.glDeleteVertexArrays(1, &vao);

    // Setup vertex and fragment shader
    const v_shader_id: u32 = try createShader(gl.GL_VERTEX_SHADER, vt_shader);
    const f_shader_id: u32 = try createShader(gl.GL_FRAGMENT_SHADER, ft_shader);
    defer gl.glDeleteShader(v_shader_id);
    defer gl.glDeleteShader(f_shader_id);
    
    const shader_program = try createProgram(v_shader_id, f_shader_id);
    defer gl.glDeleteProgram(shader_program);

    const positions: [16]f32 = [_]f32{
        -1.0, -1.0,  0.0,  0.0,
        -1.0,  1.0,  0.0,  1.0,
         1.0,  1.0,  1.0,  1.0,
         1.0, -1.0,  1.0,  0.0
    };

    const indices: [6]u32 = [_]u32{
        0, 1, 2, 2, 3, 0
    };


    // Corners of the square occupying all window
    var buffer: u32 = 0;
    gl.glGenBuffers(1, &buffer);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, positions.len * @sizeOf(f32), &positions, gl.GL_STATIC_DRAW);

    // Indices of the corner positions to draw
    var index_buffer: u32 = 0;
    gl.glGenBuffers(1, &index_buffer);
    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
    gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, indices.len * @sizeOf(u32), &indices, gl.GL_STATIC_DRAW);
  
    // First attribute of the vertex shader (vec2 position)
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));

    // Second attribute of the vertex shader (vec2 tex_Coord)
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(8));

    gl.glUseProgram(shader_program);

    const sampler_loc = gl.glGetUniformLocation(shader_program, "u_Texture");
    gl.glUniform1i(sampler_loc, 0);

    while(glfw.glfwWindowShouldClose(window) == 0) {
        gl.glDrawElements(gl.GL_TRIANGLES, indices.len, gl.GL_UNSIGNED_INT, null);
        glfw.glfwSwapBuffers(window);
        glfw.glfwWaitEvents();
    }
}

fn createTexture() u32 {
    var id: u32 = 0;
    gl.glGenTextures(1, &id);
    return id;
}

/// Creates and compiles a shader of s_type given a string
fn createShader(s_type: u32, shader: []const u8) GLError!u32 {
    const shader_id: u32 = gl.glCreateShader(s_type);
    gl.glShaderSource(shader_id, 1, @ptrCast(&shader), null);
    gl.glCompileShader(shader_id);

    // Check for compilation error
    var compile_result: i32 = 0;
    gl.glGetShaderiv(shader_id, gl.GL_COMPILE_STATUS, &compile_result);

    if (compile_result == gl.GL_FALSE) {
        var length: i32 = 0;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = fba.allocator();
        gl.glGetShaderiv(shader_id, gl.GL_INFO_LOG_LENGTH, &length);

        print("Failed to compile shader {}\n", .{ shader_id });
        const message = allocator.alloc(u8, @intCast(@abs(length))) catch {
            print("Error too long to display...\n", .{});
            return GLError.ShaderCompilationError;
        };

        defer allocator.free(message);
        gl.glGetShaderInfoLog(shader_id, @intCast(@abs(length)), &length, @ptrCast(message));

        print("{s}\n", .{ message });
        return GLError.ShaderCompilationError;
    }
    return shader_id;
}

/// Creates a shader program from vertex and fragment shader, returning the program id or error
/// Initializes all Uniform variables to 0
fn createProgram(vt_id: u32, ft_id: u32) GLError!u32 {
    const program_id = gl.glCreateProgram();
    if (program_id == 0)
        return GLError.ProgramError;

    gl.glAttachShader(program_id, vt_id);
    gl.glAttachShader(program_id, ft_id);
    gl.glLinkProgram(program_id);
    gl.glValidateProgram(program_id);

    // Check for link errors
    var link_status: i32 = 0;
    gl.glGetProgramiv(program_id, gl.GL_LINK_STATUS, &link_status);
    if (link_status == gl.GL_FALSE) {
        var length: i32 = 0;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = fba.allocator();

        gl.glGetProgramiv(program_id, gl.GL_INFO_LOG_LENGTH, &length);

        print("Shader program {} linker error:\n", .{ program_id });
        const message = allocator.alloc(u8, @intCast(@abs(length))) catch {
            print("Error too long to display...\n", .{});
            return GLError.ProgramError;
        };

        gl.glGetProgramInfoLog(program_id, @intCast(@abs(length)), &length, @ptrCast(message));
        print("{s}\n", .{ message });

        return GLError.ProgramError;
    }

    // Check for validation errors
    var validate_status: i32 = 0;
    gl.glGetProgramiv(program_id, gl.GL_VALIDATE_STATUS, &validate_status);
    if (validate_status == gl.GL_FALSE) {
        var length: i32 = 0;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = fba.allocator();

        gl.glGetProgramiv(program_id, gl.GL_INFO_LOG_LENGTH, &length);

        print("Shader program {} validation error:\n", .{ program_id });
        const message = allocator.alloc(u8, @intCast(@abs(length))) catch {
            print("Error too long to display...\n", .{});
            return GLError.ProgramError;
        };

        gl.glGetProgramInfoLog(program_id, @intCast(@abs(length)), &length, @ptrCast(message));
        print("{s}\n", .{ message });

        return GLError.ProgramError;
    }

    return program_id;
}

const GLError = error {
    ShaderCompilationError,
    ProgramError,
    WindowCreationError,
    GLInitializationError,
    GLFWInitializationError
};

const vt_shader =
\\  #version 330 core
\\  layout (location = 0) in vec2 position;
\\  layout (location = 1) in vec2 texCoord;
\\  out vec2 v_TexCoord;
\\  void main() {
\\      gl_Position = vec4(position, 0.0, 1.0);
\\      v_TexCoord = texCoord;
\\  }
;

const ft_shader =
\\  #version 330 core
\\  uniform vec4 u_Color;
\\  uniform sampler2D u_Texture;
\\  in vec2 v_TexCoord;
\\  layout (location = 0) out vec4 color;
\\  void main() {
\\      color = texture(u_Texture, v_TexCoord);
\\  }
;
