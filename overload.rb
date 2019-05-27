module Overloader
  module AstExt
    refine RubyVM::AbstractSyntaxTree::Node do
      def traverse(&block)
        block.call(self)
        children.each do |child|
          child.traverse(&block) if child.is_a?(RubyVM::AbstractSyntaxTree::Node)
        end
      end

      def find_nodes(*types)
        nodes = []
        traverse do |node|
          nodes << node if types.include?(node.type)
        end
        nodes
      end

      def method_name
        children[0]
      end

      def method_args
        children[1].children[1]
      end

      def method_body
        children[1].children[2]
      end

      def to_source(path)
        file_content(path)[first_index(path)..last_index(path)]
      end

      private def first_index(path)
        return first_column if first_lineno == 1

        lines = file_content(path).split("\n")
        lines[0..(first_lineno - 2)].sum(&:size) +
          first_lineno - 1 +
          first_column
      end

      private def last_index(path)
        last_column = self.last_column - 1
        return last_column if last_lineno == 1

        lines = file_content(path).split("\n")
        lines[0..(last_lineno - 2)].sum(&:size) +
          last_lineno - 1 +
          last_column
      end

      private def file_content(path)
        @file_content ||= {}
        @file_content[path] ||= File.binread(path)
      end
    end
  end

  def overload(&block)
    Core.define_overload(self, block)
  end

  class Core
    using AstExt

    def self.define_overload(klass, proc)
      self.new(klass, proc).define_overload
    end

    def initialize(klass, proc)
      @klass = klass
      @proc = proc
    end

    def define_overload
      ast = RubyVM::AbstractSyntaxTree.of(@proc)
      methods = {}
      ast.find_nodes(:DEFN).each.with_index do |def_node, index|
        args = def_node.method_args
        body = def_node.method_body
        name = def_node.method_name
        args_source = args.to_source(absolute_path)
        args_source = "" if args_source == "("

        @klass.class_eval <<~RUBY
          def __#{name}_#{index}_checker_inner(#{args_source}) end
          def __#{name}_#{index}_checker(*args)
            __#{name}_#{index}_checker_inner(*args)
            true
          rescue ArgumentError
            false
          end
        RUBY

        @klass.class_eval <<~RUBY, absolute_path, def_node.first_lineno
          def __#{name}_#{index}(#{args_source})
          #{body.to_source(absolute_path)}
          end
        RUBY
        (methods[name] ||= []) << index
      end

      methods.each do |name, indexes|
        @klass.class_eval <<~RUBY
          def #{name}(*args, &block)
            #{indexes.map do |index|
              "return __#{name}_#{index}(*args, &block) if __#{name}_#{index}_checker(*args)"
            end.join("\n")}
            raise ArgumentError
          end
        RUBY
      end
    end

    private

    def absolute_path
      @proc.source_location[0]
    end
  end
end

class A
  extend Overloader
  overload do
    def foo() "no arges" end
    def foo(x) "one arg" end
    def foo(x, y) "two args" end
  end
end

a = A.new
p a.foo
p a.foo(1)
p a.foo(1, 2)
